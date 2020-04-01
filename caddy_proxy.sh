docker run --rm --network caddy -p 2019:2019 alpine/socat -dd TCP-LISTEN:2019,fork TCP:caddy:2019 "$@"
