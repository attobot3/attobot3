module AttoBot3

import GitHub: name
import HTTP
import Revise

const ATTOBOT_DEFAULT_USER            = "attobot3"
const ATTOBOT_DEFAULT_REGISTRY_NAME   = "Uncurated"
const ATTOBOT_DEFAULT_REGISTRY_ORG    = "KristofferC"
const ATTOBOT_DEFAULT_REGISTRY_BRANCH = "master"
const ATTOBOT_DEFAULT_PORT            = 4567
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

const TAG_REQ = join((
    "Please make sure that:",
    "- CI passes for supported Julia versions (if applicable).",
    "- Version bounds reflect minimum requirements."
    ), '\n')

function errorissue(repo, user, message, ctx)
    GitHub.create_issue(repo, auth = ctx.auth,
        params = Dict(
            :title => "Error tagging new release",
            :body => message * "\ncc: @" * name(user)
        )
    )
    error("""
    Error when tagging: $(name(repo)) from user $(name(user)).
    Problem: $message""")
end

global CTX   = 0
global THING = 0
global LAST_EVENT = 0

function decode_file(file::GitHub.Content)
    str = String(Base.base64decode(get(file.content)))
    return replace(str, "\r\n", "\n")
end

function event_callback(event, ctx::AttoBotContext)
    global LAST_EVENT = event
    global CTX = ctx

    SANITY_CHECKS = false
    if event.kind == "release" && event.payload["action"] == "published"
        @show RELEASE   = event.payload["release"]
        @show REPO      = event.repository

        @show package   = get(REPO.name)
        @show author    = RELEASE["author"]["login"]
        @show tag_name  = RELEASE["tag_name"]
        @show html_url  = RELEASE["html_url"]

        @show bot_repo = ctx.bot_user * "/" * ctx.registry_name
        package_first_letter = first(package)

        errorissue(msg) = errorissue(REPO, author, msg, ctx)

        if endswith(package, ".jl")
            package = package[1:end-3]
        else
            SANITY_CHECKS && errorissue("The repository does not have a `.jl` suffix")
        end

        #=
        TODO: Errror check on SEMVER
        if (v isa Void) || (TAG_NAME[1] != 'v')
            errorissue("The tag name `$TAG_NAME` is not of the appropriate SemVer form (vX.Y.Z).")
        end
        =#

        # All packages should have a `versions.toml`
        VERSIONS_FILE = GitHub.file(ctx.registry_repo, "$PACKAGE_FIRST_LETTER/$PACKAGE/versions.toml"; handle_error = false, auth = ctx.auth,
                            params = Dict(
                                :ref => ctx.registry_branch
                        ))

        # TODO: Check that URL corresponds to the registered package URL

        if isnull(VERSIONS_FILE.content)
            REGISTER = false
        else
            REGISTER = true
        end

        @show REGISTER

        # 2) get the commit hash corresponding to the tag
        TAG_REF = GitHub.reference(REPO, "tags/" * tag_name; auth = ctx.auth)
        # 2a) if annotated tag: need to make another request
        if get(TAG_REF.object["type"]) == "tag"
            TAG_REF = GitHub.reference(REPO, get(TAG_REF.object["sha"]))
        end
        TAG_COMMIT = GitHub.GitCommit(get(TAG_REF.object))

        REQUIRE_FILE = GitHub.file(REPO, "REQUIRE"; handle_error = false, auth = ctx.auth,
                           params = Dict(
                               :ref => get(TAG_COMMIT.sha)
                           ))

        if isnull(REQUIRE_FILE.content)
            errorissue("No `REQUIRE` file found in repo")
        end

        require_content = decode_file(REQUIRE_FILE)

        # Change to fdsfds
        PREV_COMMIT_REF = GitHub.reference(ctx.registry_repo, "heads/" * ctx.registry_branch; auth = ctx.auth)
        global THING = PREV_COMMIT_REF
        PREV_COMMIT = GitHub.GitCommit(get(PREV_COMMIT_REF.object))

        global THING = PREV_COMMIT

        PREV_TREE = GitHub.tree(ctx.registry_repo, get(PREV_COMMIT.sha), auth = ctx.auth)
        global THING = PREV_TREE

         # 6a) create blob for REQUIRE
         blob = GitHub.create_blob(ctx.bot_name * "/" * ctx.registry_name; auth = ctx.auth,
                    params = Dict(
                        :encoding => "utf-8",
                        :content  => require_content
                    ))

        global THING = blob

        NEW_TREE = GitHub.create_tree(bot_repo; auth = ctx.auth,
                                      params = Dict(
                                          :base_tree => get(PREV_TREE.sha),
                                          :tree      => [
                                              Dict(
                                                  :path => "$PACKAGE_FIRST_LETTER/$PACKAGE/$REQUIRES",
                                                  :mode => 100644,
                                                  :type => "blob",
                                                  :sha  => get(blob.sha)
                                            )]))


        COMMIT = GitHub.create_gitcommit(bot_repo; auth = ctx.auth,
                     params = Dict(
                :message => "testmsg",
                :parents => [ get(PREV_COMMIT.sha) ],
                :tree    => get(NEW_TREE.sha),
                :author  => Dict(
                    :name  => "Test",
                    :email => "Test@hotmail.com"
                   ),
                   :committer => Dict(
                       :name  => ctx.botuser,
                       :email => ctx.botuser * "@users.noreply.github.com"
                   )))

        new_branch_name = package * "/" * tag_name
        PR_BRANCH = GitHub.create_reference(bot_repo; auth = ctx.auth, handle_error = false,
                        params = Dict(
                            :ref => "refs/heads/" * new_branch_name,
                            :sha => get(COMMIT.sha)
                   ))


        # Create the PR
        title = "Register new package " * package * " " * tag_name
        body = "Blabla...."
        PR = GitHub.create_pull_request(ctx.registry_repo; auth = ctx.auth,
            params = Dict(
                    "title" => title,
                    "body" => body,
                    "head" => ctx.botuser * ":" * new_branch_name,
                    "base" => ctx.registry_branch
                   ))

        global THING = PR
    end
    return HTTP_OK
end


function run_server()
    REGISTRY_NAME    = get(ENV, "ATTOBOT_REGISTRY_NAME",    ATTOBOT_DEFAULT_REGISTRY_NAME)
    REGISTRY_ORG     = get(ENV, "ATTOBOT_REGISTRY_ORG",     ATTOBOT_DEFAULT_REGISTRY_ORG)
    REGISTRY_BRANCH  = get(ENV, "ATTOBOT_REGISTRY_BRANCH",  ATTOBOT_DEFAULT_REGISTRY_BRANCH)
    BOT_USER         = get(ENV, "ATTOBOT_USER"),            ATTOBOT_DEFAULT_USER
    HOST_STR         = get(ENV, "ATTOBOT_HOST",             ATTOBOT_DEFAULT_PORT)
    PORT_STR         = get(ENV, "ATTOBOT_PORT",             ATTOBOT_DEFAULT_PORT)
    SECRET           = get(ENV, "ATTOBOT_SECRET",           nothing)

    if !haskey(ENV, "ATTOBOT_AUTH")
        error("The environment variable `ATTOBOT_AUTH` needs to exist and be a token that have write access to the GitHub user $BOT_USER")
    end
    AUTH = GitHub.authenticate(ENV["ATTOBOT_AUTH"])

    HOST = IPv4(HOST_STR)
    PORT = parse(Int, PORT_STR)

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
