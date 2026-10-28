#!/bin/zsh
# Deploy: rebuild and update the FDA-granted /Applications copy in place.
set -e; cd "$(dirname "$0")"; ./build.sh
# Clean replace: a ditto-merge over an old bundle can corrupt the signature,
# and an invalid signature makes TCC silently ignore the FDA grant.
rm -rf /Applications/DisktreeX.app
ditto build/DisktreeX.app /Applications/DisktreeX.app
codesign --verify --strict /Applications/DisktreeX.app
echo "==> Deployed to /Applications/DisktreeX.app (signature verified)"
