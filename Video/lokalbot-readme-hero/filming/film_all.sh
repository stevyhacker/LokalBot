#!/bin/bash
# Records every take the reel uses, in order. A host window opens about five
# times and takes focus; nobody should click it while it is open.
#   WORK=<dir> filming/film_all.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; T="$HERE/take.sh"; S="$HERE/scripts"
"$T" "$S/t-recall.json" LOKALBOT_UI_TEST_WINDOW=quick-recall LOKALBOT_CAPTURE_SIZE=660x480
"$T" "$S/t-meeting.json" LOKALBOT_FILM_HIDE_SIDEBAR=1 LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_SELECT_INDEX=3 LOKALBOT_DETAIL_TAB=summary
"$T" "$S/t-ask.json" LOKALBOT_FILM_HIDE_SIDEBAR=1 LOKALBOT_INITIAL_SECTION=ask
"$T" "$S/t-timeline.json" LOKALBOT_FILM_HIDE_SIDEBAR=1 LOKALBOT_INITIAL_SECTION=timeline
"$T" "$S/t-people.json" LOKALBOT_FILM_HIDE_SIDEBAR=1 LOKALBOT_INITIAL_SECTION=people
