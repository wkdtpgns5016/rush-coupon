#!/bin/sh
set -e

ssh-keygen -A

if [ -n "$DEPLOY_PUBLIC_KEY" ]; then
  echo "$DEPLOY_PUBLIC_KEY" > /home/deploy/.ssh/authorized_keys
  chown deploy:deploy /home/deploy/.ssh/authorized_keys
  chmod 600 /home/deploy/.ssh/authorized_keys
fi

mkdir -p /releases/dist-initial
if [ ! -e /releases/dist-initial/index.html ]; then
  echo "no release deployed yet" > /releases/dist-initial/index.html
fi
if [ ! -e /releases/current ]; then
  ln -sfn dist-initial /releases/current
fi
chown -R deploy:deploy /releases

/usr/sbin/sshd
exec nginx -g 'daemon off;'
