#!/bin/sh
echo $$ > "$2"
printf '%s\n' '{"ready":true,"frame_samples":512}'
IFS= read -r request
. "$3/response.sh"
