module AttoBot3

import GitHub: GitHub, name
import HTTP
import Revise
import JSON
import SHA
import Base.Random: UUID

const ATTOBOT_DEFAULT_USER            = "attobot3"
const ATTOBOT_DEFAULT_REGISTRY_NAME   = "Uncurated"
const ATTOBOT_DEFAULT_REGISTRY_ORG    = "KristofferC"
const ATTOBOT_DEFAULT_REGISTRY_BRANCH = "master"
const ATTOBOT_DEFAULT_PORT            = "4567"
const ATTOBOT_DEFAULT_HOST            = "127.0.0.1"

const HTTP_OK = HTTP.Response(200)

struct AttoBotContext
    regname   :: String
    regorg    :: String
    regrepo   :: String
    regbranch :: String
    botuser   :: String
    auth
end

# From Pkg3.jl
function uuid5(namespace::UUID, key::String)
    data = [reinterpret(UInt8, [namespace.value]); Vector{UInt8}(key)]
    u = reinterpret(UInt128, SHA.sha1(data)[1:16])[1]
    u &= 0xffffffffffff0fff3fffffffffffffff
    u |= 0x00000000000050008000000000000000
    return UUID(u)
end
uuid5(namespace::UUID, key::AbstractString) = uuid5(namespace, String(key))

const UUID_DNS = UUID(0x6ba7b810_9dad_11d1_80b4_00c04fd430c8)
const UUID_JULIA = uuid5(UUID_DNS, "julialang.org")
const UUID_PACKAGE = uuid5(UUID_JULIA, "package")

const TAG_REQ = """
    Please make sure that:,
    - CI passes for supported Julia versions (if applicable).,
    - Version bounds reflect minimum requirements.

    """

function _errorissue(repo, user, message, ctx)
    GitHub.create_issue(repo, auth = ctx.auth,
        params = Dict(
            :title => "Error tagging new release",
            :body => message * "\ncc: @" * name(user)
        )
    )
    return HTTP_OK
end

global CTX   = 0
global THING = 0
global LAST_EVENT = 0

function decode_file(file::GitHub.Content)
    @assert get(file.encoding) == "base64" # GitHub says this will always be the case
    str = String(Base.base64decode(get(file.content)))
    return replace(str, "\r\n", "\n")
end

function event_callback(event, ctx::AttoBotContext)
    global LAST_EVENT = event
    global CTX = ctx

    SANITY_CHECKS = false

    if event.kind == "pull_request" && event.payload["action"] == "closed"

        repo = event.repository
        @show name(repo) == ctx.regrepo
        if name(repo) != ctx.regrepo
            return HTTP_OK
        end

        PR = GitHub.PullRequest(event.payload["pull_request"])
        @show (get(PR.user).login) == ctx.botuser
        if get(get(PR.user).login) != ctx.botuser
            return HTTP_OK
        end

        @show isnull(PR.merged_at)
        if isnull(PR.merged_at)
            sleep(25)
            PR2 = GitHub.pull_request(ctx.regrepo, PR)
            # Branch got reopened
            if get(PR2.state) != "closed"
                return HTTP_OK
            end
        end

        branch = get(get(PR.head).ref)
        GitHub.delete_reference(ctx.botuser * "/" * ctx.regname, "heads/$branch"; auth = ctx.auth)
    end

    if event.kind == "release" && event.payload["action"] == "published"
        RELEASE   = event.payload["release"]
        REPO      = event.repository
        package   = get(REPO.name)
        author    = RELEASE["author"]["login"]
        tag_name  = RELEASE["tag_name"]
        tag_url   = RELEASE["html_url"]
        html_url  = get(REPO.html_url)
        bot_repo  = ctx.botuser * "/" * ctx.regname
        package_first_letter = uppercase(first(package))

        errorissue(msg) = _errorissue(REPO, author, msg, ctx)

        if endswith(package, ".jl")
            package = package[1:end-3]
        else
            SANITY_CHECKS && return errorissue("The repository does not have a `.jl` suffix")
        end

        #=
        TODO: Errror check on SEMVER
        if (v isa Void) || (tag_name[1] != 'v')
            errorissue("The tag name `$tag_name` is not of the appropriate SemVer form (vX.Y.Z).")
        end
        =#

        # All packages should have a `package.toml`
        REGISTRY_PACKAGE_FILE = GitHub.file(ctx.regrepo, "$package_first_letter/$package/package.toml";
                                        handle_error = false, auth = ctx.auth,
                                        params = Dict(
                                            "ref" => ctx.regbranch
                                        ))


        if isnull(REGISTRY_PACKAGE_FILE.content)
            register = true
        else
            register = false

            # Verify that the tag came from the repo that is registered in the registry
            registry_package_toml = Pkg3.TOML.parse(decode_file(REGISTRY_PACKAGE_FILE))
            registered_package_url = registry_package_toml["repo"]

            if !(html_url in registered_package_url) # Pkg3 seems to only use https
                return errorissue("The repo this package was registered from ($html_url) does not correspond to the one found in the registry: ($registered_package_url)")
            end


            VERSIONS_FILE = GitHub.file(REPO, "$package_first_letter/$package/versions.toml", auth = ctx.auth,
                                params = Dict(
                                    "ref" => ctx.regbranch
                                ))

            versions_toml = Pkg3.TOML.parse(decode_file(VERSIONS_FILE))
            versions = sort(VersionInfo.(collect(keys(versions_toml))))
            #=
            if v in versions
                return errorissue("The version $v is already registered.")
            end

            earlier_version = last(searchsorted(versions, v))

            if last(closest_version) == 0
                return errorissue("Cannot tag a new version, $tag_name preceding all existing versions.")
            end
            =#

            # Need to generate the new compatability here...

            # TODO find reqs for that versio
        end



        # 2) get the commit hash corresponding to the tag
        TAG_REF = GitHub.reference(REPO, "tags/" * tag_name; auth = ctx.auth)
        # 2a) if annotated tag: need to make another request
        if get(TAG_REF.object)["type"] == "tag"
            TAG_REF = GitHub.reference(REPO, get(TAG_REF.object)["sha"])
        end
        TAG_COMMIT = GitHub.GitCommit(get(TAG_REF.object))

        REQUIRE_FILE = GitHub.file(REPO, "REQUIRE"; handle_error = false, auth = ctx.auth,
                           params = Dict(
                               "ref" => get(TAG_COMMIT.sha)
                           ))

        if isnull(REQUIRE_FILE.content)
            return errorissue("No `REQUIRE` file found in repo")
        end

        require_content = decode_file(REQUIRE_FILE)

        # Change to fdsfds
        PREV_COMMIT_REF = GitHub.reference(ctx.regrepo, "heads/" * ctx.regbranch; auth = ctx.auth)
        global THING = PREV_COMMIT_REF
        PREV_COMMIT = GitHub.GitCommit(get(PREV_COMMIT_REF.object))

        global THING = PREV_COMMIT

        PREV_TREE = GitHub.tree(ctx.regrepo, get(PREV_COMMIT.sha), auth = ctx.auth)
        global THING = PREV_TREE

        # 6a) create blob for REQUIRE
        REQUIRE_BLOB = GitHub.create_blob(ctx.botuser * "/" * ctx.regname; auth = ctx.auth,
                           params = Dict(
                               "encoding" => "utf-8",
                               "content"  => require_content
                           ))

        if register
            package_content = """
            name = \"$package\"
            uuid = \"$(uuid5(UUID_PACKAGE, package))\"
            repo = \"$html_url\"
            """
            PACKAGE_BLOB = GitHub.create_blob(ctx.botuser * "/" * ctx.regname; auth = ctx.auth,
                           params = Dict(
                            "encoding" => "utf-8",
                            "content"  => package_content
                        ))
        end


        tree_data = Dict(
                       "base_tree" => get(PREV_TREE.sha),
                       "tree"      => [
                           Dict(
                               "path" => "$package_first_letter/$package/REQUIRES",
                               "mode" => "100644",
                               "type" => "blob",
                               "sha"  => get(REQUIRE_BLOB.sha)
                           )])

        if register
            push!(tree_data["tree"],
                    Dict(
                        "path" => "$package_first_letter/$package/package.toml",
                        "mode" => "100644",
                        "type" => "blob",
                        "sha" => get(PACKAGE_BLOB.sha)
                    ))
        end

        NEW_TREE = GitHub.create_tree(bot_repo; auth = ctx.auth,
                       params = tree_data)

        # Get user name and email
        AUTHOR = GitHub.owner(author; handle_error = false, auth = ctx.auth)
        author_name = isnull(AUTHOR.name) ? author : get(AUTHOR.name)
        global THING = AUTHOR
        @show author_name

        if isnull(AUTHOR.email)
            AUTHOR_COMMITS, page_data = GitHub.commits(REPO, auth = ctx.auth)
            if !isempty(AUTHOR_COMMITS)
                author_email = get(get(get(AUTHOR_COMMITS[1].commit).author).email)
            else
                author_email = author * "@users.noreply.github.com"
            end
        else
            author_email = get(AUTHOR.email)
        end

        COMMIT = GitHub.create_gitcommit(bot_repo; auth = ctx.auth,
                     params = Dict(
                         "message"   => "testmsg",
                         "parents"   => [ get(PREV_COMMIT.sha) ],
                         "tree"      => get(NEW_TREE.sha),
                         "author"    => Dict(
                             "name"  => author_name,
                             "email" => author_email
                         ),
                         "committer" => Dict(
                             "name"  => ctx.botuser,
                             "email" => ctx.botuser * "@users.noreply.github.com"
                         )))

        new_branch_name = package * "/" * tag_name
        PR_REF = GitHub.create_reference(bot_repo; auth = ctx.auth, handle_error = false,
                        params = Dict(
                            "ref" => "refs/heads/" * new_branch_name,
                            "sha" => get(COMMIT.sha)
                   ))
        existing = false

        # Branch already exists
        if isnull(PR_REF.object)
            info("Force pushing to $new_branch_name with sha $(get(COMMIT.sha))")
            PR_REF = GitHub.update_reference(bot_repo, "heads/$new_branch_name"; auth = ctx.auth,
                params = Dict(
                    "sha"   => get(COMMIT.sha),
                    "force" => true
                ))
            existing = true
        end

        global THING = PR_REF

        # Temp set a repo name here to test
        travis_pr_line = ""
        r = HTTP.get("https://api.travis-ci.org/repos/$(ctx.regrepo)/branches/$tag_name"; statusraise = false)
        if r.status == 200 # check
            rj = JSON.parse(String(r))
            build_id = string(rj["branch"]["id"])
            if get(TAG_REF) == rj["commit"]["sha"]
                badge_url = "https://api.travis-ci.org/$(ctx.regrepo).svg?branch=$tag_name"
                build_url = "https://travis-ci.org/$(ctx.regrepo)/builds/build_id"
                travis_pr_line = "Travis: [![Travis Build Status]($badge_url)]($build_url)\n"
            end
        end

        # Branch already exists on the bot repo which means that a PR is currently in progress.
        # Update that PR instead
        if existing

            PRS, page_data = GitHub.pull_requests(ctx.regrepo; auth = ctx.auth,
                                 params = Dict(
                                     "head" => ctx.botuser * ":" * new_branch_name,
                                     "state" => "all"
                                    ))
            PR = PRS[1]

            GitHub.create_comment(ctx.regrepo, PR; auth = ctx.auth,
                params = Dict(
                    "body" => "comment..."
                ))

        # Create a new PR
        else
            body = """
            Repository: [$(name(REPO))]($html_url)
            Release: [$tag_name]($tag_url)

            """

            body *= travis_pr_line
                # Package has not been registered before
            if register

            else
                body *= "Diff link"
                body *= "Diff require"
            end

            title = (register ? "Register" : "Tag") * " $package $tag_name"

            # Create the PR
            body *= """
            cc: @$(author)

            $TAG_REQ
            """

            if register
                body *= """
                    @$(author) This PR will remain open for 24 hours for feedback (which is optional). If you get feedback, please let us know if you are making changes, and we'll merge once you're done.
                """

                PR = GitHub.create_pull_request(ctx.regrepo; auth = ctx.auth,
                    params = Dict(
                            "title" => title,
                            "body" => body,
                            "head" => ctx.botuser * ":" * new_branch_name,
                            "base" => ctx.regbranch
                           ))
            end
        end
    end
    return HTTP_OK
end


function run_server()
    REGISTRY_NAME    = get(ENV, "ATTOBOT_REGISTRY_NAME",    ATTOBOT_DEFAULT_REGISTRY_NAME)
    REGISTRY_ORG     = get(ENV, "ATTOBOT_REGISTRY_ORG",     ATTOBOT_DEFAULT_REGISTRY_ORG)
    REGISTRY_BRANCH  = get(ENV, "ATTOBOT_REGISTRY_BRANCH",  ATTOBOT_DEFAULT_REGISTRY_BRANCH)
    BOT_USER         = get(ENV, "ATTOBOT_USER",             ATTOBOT_DEFAULT_USER)
    HOST_STR         = get(ENV, "ATTOBOT_HOST",             ATTOBOT_DEFAULT_HOST)
    PORT_STR         = get(ENV, "ATTOBOT_PORT",             ATTOBOT_DEFAULT_PORT)
    SECRET           = get(ENV, "ATTOBOT_SECRET",           nothing)

    HOST = IPv4(HOST_STR)
    PORT = parse(Int, PORT_STR)

    if !haskey(ENV, "ATTOBOT_AUTH")
        error("The environment variable `ATTOBOT_AUTH` needs to exist and be a token that have write access to the GitHub user $BOT_USER")
    end
    AUTH = GitHub.authenticate(ENV["ATTOBOT_AUTH"])

    CTX = AttoBotContext(REGISTRY_NAME,
                         REGISTRY_ORG,
                         REGISTRY_ORG * "/" * REGISTRY_NAME,
                         REGISTRY_BRANCH,
                         BOT_USER,
                         AUTH)

    if SECRET == nothing
        warn("Running server without a secret key, events from all sources will be accepted. This is a dangerous setting!")
    end

    listener = GitHub.EventListener() do event
        Revise.revise()
        Base.invokelatest(event_callback, event, CTX)
    end
    GitHub.run(listener, IPv4(127, 0, 0, 1), 4567)
    wait()
end

end # module
