#!/bin/bash
#
# Functions taken from openstack/infra/devstack-gate
# https://github.com/openstack-infra/devstack-gate/blob/master/functions.sh

function git_fetch_at_ref {
    local project=$1
    local ref=$2
    if [ "$ref" != "" ]; then
        git fetch $ZUUL_URL/$project $ref
        return $?
    else
        # return failing
        return 1
    fi
}

function git_checkout {
    local project=$1
    local branch=$2
    local reset_branch=$branch

    if [[ "$branch" != "FETCH_HEAD" ]]; then
        reset_branch="remotes/origin/$branch"
    fi

    git checkout $branch
    git reset --hard $reset_branch
    if ! git clean -x -f -d -q ; then
        sleep 1
        git clean -x -f -d -q
    fi
}

function git_has_branch {
    local project=$1 # Project is here for test mocks
    local branch=$2

    if git branch -a |grep remotes/origin/$branch>/dev/null; then
        return 0
    else
        return 1
    fi
}

function git_prune {
    git_timed remote prune origin
}

function git_remote_update {
    git_timed remote update
}

# git can sometimes get itself infinitely stuck with transient network
# errors or other issues with the remote end.  This wraps git in a
# timeout/retry loop and is intended to watch over non-local git
# processes that might hang. Run for up to 5 minutes before killing.
# If first SIGTERM does not kill the process wait a minute then SIGKILL.
# If the git operation fails try again for up to a total of 3 attempts.
# usage: git_timed <git-command>
function git_timed {
    local max_attempts=3
    local count=0
    until timeout -k 1m 5m git "$@"; do
        count=$(($count + 1))
        echo "git $@ failed."
        if [ $count -eq $max_attempts ]; then
            echo "Max attempts reached for git $@; giving up."
            exit 1
        fi
        local sleep_time=$((30 + $RANDOM % 60))
        echo "sleep $sleep_time before retrying."
        sleep $sleep_time
    done
}

function git_remote_set_url {
    git remote set-url $1 $2
}

function git_clone_and_cd {
    local project=$1
    local short_project=$2
    local git_base=${GIT_BASE:-https://git.openstack.org}

    if [[ ! -e $short_project ]]; then
        echo "  Need to clone $short_project"
        git clone $git_base/$project
    fi
    cd $short_project
}

# Removing ironic and requirements projects only.
# openstack/requirements is always left with "upper-constraints"
# file in modified state. So if any update to the requirements
# project is not reflected in the /opt/stack/requirements directory.
# openstack/ironic may be left in unsane state due to merge conflicts
# of the patch. This leads to gate failing for subsequent run as the
# new patch cannot be applied unless the directory /opt/stack/ironic is
# cleaned up manually.
function remove_git_repos {
    local short_project=$1
    if [[ -e $short_project ]] && [[ $short_project == "ironic" || $short_project == "requirements" ]]; then
        echo "Removing the repo directory $short_project"
        sudo rm -rf /opt/stack/$short_project
    fi
}

# Set up a project in accordance with the future state proposed by
# Zuul.
#
# Arguments:
#   project: The full name of the project to set up
#   branch: The branch to check out
#
# The branch argument should be the desired branch to check out.  If
# you have no other opinions, then you should supply ZUUL_BRANCH here.
# This is generally the branch corresponding with the change being
# tested.
#
function setup_project {
    local project=$1
    local branch=$2
    local short_project=`basename $project`
    local git_base=${GIT_BASE:-https://git.openstack.org}

    remove_git_repos $short_project

    echo "Setting up $project @ $branch"
    git_clone_and_cd $project $short_project

    git_remote_set_url origin $git_base/$project

    # allow for possible project branch override
    local uc_project=`echo $short_project | tr [:lower:] [:upper:] | tr '-' '_' | sed 's/[^A-Z_]//'`
    local project_branch_var="\$OVERRIDE_${uc_project}_PROJECT_BRANCH"
    local project_branch=`eval echo ${project_branch_var}`
    if [[ "$project_branch" != "" ]]; then
        branch=$project_branch
    fi

    # Try the specified branch before the ZUUL_BRANCH.
    if [[ ! -z $ZUUL_BRANCH ]]; then
        OVERRIDE_ZUUL_REF=$(echo $ZUUL_REF | sed -e "s,$ZUUL_BRANCH,$branch,")
    else
        OVERRIDE_ZUUL_REF=""
    fi


    # Update git remotes
    git_remote_update
    # Ensure that we don't have stale remotes around
    git_prune
    # See if this project has this branch, if not, use master
    FALLBACK_ZUUL_REF=""
    if ! git_has_branch $project $branch; then
        FALLBACK_ZUUL_REF=$(echo $ZUUL_REF | sed -e "s,$branch,master,")
    fi

    # See if Zuul prepared a ref for this project
    if git_fetch_at_ref $project $OVERRIDE_ZUUL_REF || \
        git_fetch_at_ref $project $FALLBACK_ZUUL_REF; then

        # It's there, so check it out.
        git_checkout $project FETCH_HEAD
    else
        if git_has_branch $project $branch; then
            git_checkout $project $branch
        else
            git_checkout $project master
        fi
    fi
}
