FROM alpine:3.20
RUN apk add --no-cache \
    postfix \
    cyrus-sasl \
    libsasl \
    cyrus-sasl-login \
    ca-certificates tzdata \
 && mkdir -p /var/spool/postfix /var/run/saslauthd /etc/sasl2 \
 && chown -R postfix:postfix /var/spool/postfix
COPY postfix/ /etc/postfix/
COPY sasl/ /etc/sasl2/
EXPOSE 587
CMD ["postfix", "start-fg"]
