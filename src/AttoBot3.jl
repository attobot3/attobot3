module AttoBot3

import GitHub
import HTTP
import Base.LibGit2
import Revise

const ATTOBOT_DEFAULT_API             = "https://api.github.com/"
const ATTOBOT_DEFAULT_REGISTRY_NAME   = "Uncurated"
const ATTOBOT_DEFAULT_REGISTRY_ORG    = "KristofferC"
const ATTOBOT_DEFAULT_REGISTRY_BRANCH = "master"
const ATTOBOT_DEFAULT_ID              = 6187
const ATTOBOT_DEFAULT_PRIVATE_KEY_FILE  = joinpath(@__DIR__, "..", "attobot-private-key.pem")
const HTTP_OK = HTTP.Response(200)


struct AttoBotContext
    id::Int
    api::String
    registry_name::String
    registry_org::String
    registry_branch::String
    private_key_file::String
end

function is_package_registered(pkg::String, ctx::AttoBotContext)

end

function unpack(b_null, args...)
    isnull(b_null) && return Nullable()
    b = get(b_null)
    for arg in args
        b_null = getfield(b, arg)
        isnull(b_null) && return Nullable()
        b = get(b_null)
    end
    return b
end

function run_server()
    API              = get(ENV, "ATTOBOT_API",              ATTOBOT_DEFAULT_API)
    REGISTRY_NAME    = get(ENV, "ATTOBOT_REGISTRY_NAME",    ATTOBOT_DEFAULT_REGISTRY_NAME)
    REGISTRY_ORG     = get(ENV, "ATTOBOT_REGISTRY_ORG",     ATTOBOT_DEFAULT_REGISTRY_ORG)
    REGISTRY_BRANCH  = get(ENV, "ATTOBOT_REGISTRY_BRANCH",  ATTOBOT_DEFAULT_REGISTRY_BRANCH)
    PRIVATE_KEY_FILE = get(ENV, "ATTOBOT_PRIVATE_KEY_FILE", ATTOBOT_DEFAULT_PRIVATE_KEY_FILE)
    SECRET           = get(ENV, "ATTOBOT_SECRET",           nothing)
    ID               = haskey(ENV, "ATTOBOT_ID") ? parse(Int, ENV["ATTOBOT_ID"]) : ATTOBOT_DEFAULT_ID

    if SECRET == nothing
        warn("Running server without a secret key, events from all sources will be accepted. This is dangerous!")
    end

    ctx = AttoBotContext(ID, API, REGISTRY_NAME, REGISTRY_ORG, REGISTRY_BRANCH, PRIVATE_KEY_FILE)

    listener = GitHub.EventListener() do event
        Revise.revise()
        Base.invokelatest(event_callback, event, ctx)
    end
    GitHub.run(listener, IPv4(127,0,0,1), 4567)
    wait()
end

global LAST_EVENT


function package_exist()
    
end

function event_callback(event, ctx::AttoBotContext)
    global LAST_EVENT = event
    @show event
    if event.kind == "release" && event.payload["action"] == "published"
        # auth = getauth(event, ctx)

        # 1

        release = event.payload["release"]

        @show package  = release["name"]
        @show author   = release["author"]["login"]
        @show tag_name = release["tag_name"]
        @show html_url = release["html_url"]

        author = GitHub.owner(release["author"]["login"])
    
        #r = Requests.get(
        #=
        author_email = author.email
        if isnull(email)
            # Try get email from commits
            commits, page_data = GitHub.commits(repo, params = Dict(:author = author))
            if !isempty(commits)
                author_email = get(unpack(commits[1].commit, :author, :email),
                                   get(author.login) * "@users.noreply.github.com")
            end
        end
        =#

    end
    return HTTP_OK
end

function getauth(event, ctx::AttoBotContext)
    appauth = GitHub.JWTAuth(ctx.id, ctx.private_key_file)
    installation = GitHub.Installation(event.payload["installation"])
    auth = GitHub.create_access_token(installation, appauth)
    return auth
end

end # module
