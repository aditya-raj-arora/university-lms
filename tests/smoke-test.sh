#!/bin/sh
set -u

BASE_URL="${1:-http://127.0.0.1}"
FAILED=0
ATTEMPTS=0

until PAGE=$(wget -qO- "$BASE_URL/" 2>/dev/null); do
    ATTEMPTS=$((ATTEMPTS + 1))
    if [ "$ATTEMPTS" -ge 15 ]; then
        echo "FAIL  $BASE_URL is not reachable"
        exit 1
    fi
    sleep 1
done

check() {
    if echo "$PAGE" | grep -q "$1"; then
        echo "PASS  $2"
    else
        echo "FAIL  $2"
        FAILED=1
    fi
}

check "<title>University Learning Management Portal</title>" "Page title"
check 'id="courses"' "Course information section"
check 'id="faculty"' "Faculty profiles section"
check 'id="resources"' "Learning resources section"
check 'id="announcements"' "Assignment announcements section"
check 'id="exams"' "Examination schedule section"

if wget -q --spider "$BASE_URL/styles.css"; then
    echo "PASS  Stylesheet is served"
else
    echo "FAIL  Stylesheet is served"
    FAILED=1
fi

exit "$FAILED"
