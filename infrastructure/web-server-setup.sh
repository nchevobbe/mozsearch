#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

if [ $# != 4 -a $# != 5 -a $# != 6 ]
then
    echo "usage: $0 <config-repo-path> <config-file-name> <index-path> <server-root> [<use_hsts>] [nginx-cache-dir]"
    exit 1
fi

MOZSEARCH_PATH=$(readlink -f $(dirname "$0")/..)

CONFIG_REPO=$(readlink -f $1)
CONFIG_INPUT="$2"
WORKING=$(readlink -f $3)
CONFIG_FILE=$WORKING/config.json
SERVER_ROOT=$(readlink -f $4)
USE_HSTS=${5:-}
NGINX_CACHE_DIR=${6:-}

$MOZSEARCH_PATH/scripts/generate-config.sh $CONFIG_REPO $CONFIG_INPUT $WORKING

sudo mkdir -p /etc/nginx/sites-enabled
sudo rm -f /etc/nginx/sites-enabled/default

rm -rf $SERVER_ROOT/docroot
mkdir -p $SERVER_ROOT/docroot
DOCROOT=$(realpath $SERVER_ROOT/docroot)

DEFAULT_TREE_NAME=$(jq -r ".default_tree // empty" ${CONFIG_FILE})

for TREE_NAME in $(jq -r ".trees|keys_unsorted|.[]" ${CONFIG_FILE})
do
    mkdir -p $DOCROOT/file/$TREE_NAME
    mkdir -p $DOCROOT/dir/$TREE_NAME
    mkdir -p $DOCROOT/raw-analysis/$TREE_NAME
    mkdir -p $DOCROOT/file-lists/$TREE_NAME/file-lists
    ln -s $WORKING/$TREE_NAME/file $DOCROOT/file/$TREE_NAME/source
    ln -s $WORKING/$TREE_NAME/dir $DOCROOT/dir/$TREE_NAME/source
    ln -s $WORKING/$TREE_NAME/analysis $DOCROOT/raw-analysis/$TREE_NAME/raw-analysis
    for FILE_LIST in repo-files objdir-files; do
        ln -s $WORKING/$TREE_NAME/$FILE_LIST $DOCROOT/file-lists/$TREE_NAME/file-lists/$FILE_LIST
    done

    # Only update the help file if no default tree was specified OR
    # The tree was specified and this is that tree.
    if [ -z "$DEFAULT_TREE_NAME" -o "$DEFAULT_TREE_NAME" == "$TREE_NAME" ]
    then
        rm -f $DOCROOT/help.html
        ln -s $WORKING/$TREE_NAME/templates/help.html $DOCROOT
    fi
done

$MOZSEARCH_PATH/scripts/nginx-setup.py $CONFIG_FILE $DOCROOT "$USE_HSTS" "$NGINX_CACHE_DIR" > /tmp/nginx
sudo mv /tmp/nginx /etc/nginx/sites-enabled/mozsearch.conf
sudo chmod 0644 /etc/nginx/sites-enabled/mozsearch.conf

# Iterate over the tree names in order of increasing priority so that we can
# make sure that the most important (by higher priority value) trees get their
# data cached last so if we run out of spare memory capacity, it's the less
# important trees that get their data evicted.
#
# (If we wanted decreasing priority, we would `reverse` the array after sorting.)
for TREE_NAME in $(jq -r ".trees|to_entries|sort_by(.value.priority)|.[].key" ${CONFIG_FILE})
do
    # source load-vars.sh to get our `cache_when_*` helpers.
    . $MOZSEARCH_PATH/scripts/load-vars.sh $CONFIG_FILE $TREE_NAME

    # The livegrep.idx is the most important file, so it's always the last thing
    # we cache.  These helpers also take into considerationg the "cache" setting
    # in the tree config.
    cache_when_everything crossref-extra
    cache_when_everything crossref
    cache_when_codesearch livegrep.idx
done

# Under docker nginx might not be running, in which case we need to start it,
# but only if we don't see existing processes.
pgrep nginx || sudo /etc/init.d/nginx start
sudo /etc/init.d/nginx reload
