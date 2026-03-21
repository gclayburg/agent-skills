# Prerequisites

`buildgit` sits on top of an existing git + Jenkins setup. You'll need:

- **bash**, **curl**, **jq**
- **Git** for your project, with a remote repository
- **Jenkins** with a **Pipeline** or **Multibranch Pipeline** job for your project (freestyle jobs are not supported)
- **Automatic build triggers** — your git remote must be configured to trigger a Jenkins build on every push (e.g. via a webhook, a git post-receive hook, or a Jenkins plugin like GitHub Branch Source). buildgit monitors builds; it doesn't create the link between your repo and Jenkins.

### Jenkins user setup

buildgit needs a Jenkins user with read and build permissions. It does **not** need any administrative access. The minimum required permissions are:

- **Overall/Read** — connect to Jenkins
- **Job/Read** — view job and build details
- **Job/Build** — trigger new builds (only needed for `buildgit build`)

The user does not need permissions to create, delete, configure, or administer jobs or Jenkins itself. A role with just these permissions keeps the attack surface small.

### Jenkins credentials

Once you have a Jenkins user, generate an API token and set these environment variables (e.g. in your `~/.bashrc` or `~/.zshrc`):

```bash
export JENKINS_URL="https://jenkins.example.com"
export JENKINS_USER_ID="your-username"
export JENKINS_API_TOKEN="your-api-token"
```

To generate an API token: Jenkins > your user > Configure > API Token > Add new Token.

### Project setup

Add the Jenkins job name to your project's root `CLAUDE.md` or `AGENTS.md`:

```markdown
## Jenkins CI
- JOB_NAME=my-project
```

This lets buildgit match your project to the Jenkins job automatically.

To override this inferred jobname, use `--job`:

```bash
buildgit --job jenkins-job-name status
buildgit --job jenkins-job-name/main status
```

### Using with docker sandbox

This tool can be used within a Docker sandbox: https://docs.docker.com/ai/sandboxes/
You'll need to expand your sandbox to be able to use this tool within the sandbox to access the Jenkins server on the outside.

Make sure your Docker sandbox has the JENKINS env variables set up in each microVM container.
Here is how to do it with Claude:

1. `cd <your-project>`
2. Run your sandbox of choice:
$ `docker sandbox run claude .`
3. Go through any authentication steps needed — subscription or API key. Exit Claude Code.
4. Make sure the JENKINS env variables are set in your shell.  
5. Run this prompt through the agent running in the container. It will persist the env values for next time: 

```
$ docker sandbox run claude . -- --model haiku -p "
replace these env settings to your context in /etc/sandbox-persistent.sh:
export JENKINS_URL=$JENKINS_URL
export JENKINS_USER_ID=$JENKINS_USER_ID
export JENKINS_API_TOKEN=$JENKINS_API_TOKEN
export GIT_HTTPS_USER=$GIT_HTTPS_USER
export GIT_HTTPS_TOKEN=$GIT_HTTPS_TOKEN
"
```

If you are using Codex, you'll need to go through similar auth steps as above. Set the env variables like this:

```
docker sandbox run codex . -- exec --model gpt-5.1-codex-mini "
replace these env settings to your context in /etc/sandbox-persistent.sh:
export JENKINS_URL=$JENKINS_URL
export JENKINS_USER_ID=$JENKINS_USER_ID
export JENKINS_API_TOKEN=$JENKINS_API_TOKEN
export GIT_HTTPS_USER=$GIT_HTTPS_USER
export GIT_HTTPS_TOKEN=$GIT_HTTPS_TOKEN
"
```


6. Optional — check that these settings are saved in the container under `/etc/sandbox-persistent.sh`.

Check the build status:

```
$ docker sandbox run codex . -- exec --model gpt-5.1-codex-mini 'what is the build status'
$ docker sandbox run claude . -- --model haiku -p  'what is the build status'
```

**Fix Docker sandbox proxy errors.** Allow access for your `JENKINS_URL` and git https host:

```
$ docker sandbox network proxy codex-phandlemono --policy allow --allow-host palmer.garyclayburg.com --allow-host jenkins.garyclayburg.com --allow-host git.garyclaybug.com
```

### git https permissions
Here we are setting up git to use basic auth from env variables.
This is needed to allow your sandbox to push code to the remote git https server:

```
git config credential.helper '!f() { echo "username=${GIT_HTTPS_USER}"; echo "password=${GIT_HTTPS_TOKEN}"; }; f'
export GIT_HTTPS_USER=<your-git-user>
export GIT_HTTPS_TOKEN=<your-git-password>
```
