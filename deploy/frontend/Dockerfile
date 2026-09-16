FROM nginx:alpine

RUN apk add --no-cache openssh-server \
    && adduser -D -s /bin/sh deploy \
    && passwd -u deploy \
    && mkdir -p /home/deploy/.ssh \
    && chmod 700 /home/deploy/.ssh \
    && chown -R deploy:deploy /home/deploy/.ssh

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80 22
ENTRYPOINT ["/entrypoint.sh"]
