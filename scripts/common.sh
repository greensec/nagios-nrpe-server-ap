GREEN="\e[32m"
RED="\e[31m"
BOLDGREEN="\e[1;32m"
BOLDRED="\e[1;31m"
ENDCOLOR="\e[0m"
BHOME="$PWD"

function statusline {
    echo -e "${BOLDGREEN}[*]${ENDCOLOR} \e[1m$@${ENDCOLOR}"
}

function errorline {
    echo -e "${BOLDRED}[*]${ENDCOLOR} \e[1m$@${ENDCOLOR}"
}
