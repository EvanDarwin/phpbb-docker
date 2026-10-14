#!/bin/sh
# Upgrading SQLite boards in place. A board made by the last published image tests
# the migration from it (weak-password warning, merges from its 3.3.15 files,
# backup); boards made by an older build of this image test merge conflicts,
# upgrades from a saved merge base, refused downgrades, and failed writes.
. "$(dirname "$0")/lib.sh"

version=$(image_phpbb_version "$IMAGE")
old_version=$(image_phpbb_version "$OLD_IMAGE")
# A template phpBB changed between 3.3.15 and 3.3.16+, and the new line it contains
VF=styles/prosilver/template/viewforum_body.html
NEW_LINE='topicrow.U_NEWEST_POST and topicrow.S_UNREAD_TOPIC'
sqlite_version() { docker exec "$(c "$1")" sqlite3 /opt/phpbb/phpbb.sqlite "SELECT config_value FROM phpbb_config WHERE config_name='version'"; }
in_data() { docker exec "$(c "$1")" sh -c "cd $DATA && $2"; }

echo "Board from the last published image (phpBB $LEGACY_PHPBB_VERSION), with admin edits"
legacy_board legacy1 board1
on_volume board1 "cd $DATA \
  && sed -i '1i <!-- admin edit: top -->' $VF \
  && echo '<!-- admin header edit -->' >> styles/prosilver/template/overall_header.html \
  && echo custom > images/smilies/icon_e_smile.gif && rm images/smilies/icon_cry.gif \
  && mkdir -p styles/mystyle ext/acme/demo language/de \
  && touch styles/mystyle/style.cfg ext/acme/demo/composer.json language/de/common.php \
  && echo attachment > files/test_attachment"
# No PHPBB_PASSWORD: the board's admin password may be one the old image generated
start up1 "$IMAGE" -v "$(vol board1):/opt/phpbb"
check "container is running" running up1
check_eq "database upgraded to phpBB $version" "$version" "$(sqlite_version up1)"
check_eq "admin logs in with the old password" 2 "$(login up1 admin "$T_PASSWORD")"
check_eq "marked as installed by an older image" 1 "$(in_data up1 'cat .docker-install-version')"
check_has "weak-password warning shown" "SECURITY WARNING" "$(logs up1)"
check "admin edit kept in a file phpBB changed" in_data up1 "grep -q 'admin edit: top' $VF"
check "phpBB's change merged into that file" in_data up1 "grep -q '$NEW_LINE' $VF"
check "admin edit kept in a file phpBB didn't change" in_data up1 "grep -q 'admin header edit' styles/prosilver/template/overall_header.html"
check_eq "replaced stock smiley kept" custom "$(in_data up1 'cat images/smilies/icon_e_smile.gif')"
check_fails "deleted stock smiley stays deleted" in_data up1 "test -e images/smilies/icon_cry.gif"
check "added style, extension, language pack and attachment kept" in_data up1 \
  "test -f styles/mystyle/style.cfg && test -f ext/acme/demo/composer.json && test -f language/de/common.php && test -f files/test_attachment"
check "files new in phpBB $version added" in_data up1 "test -f language/en/email/update_security.txt"
check_eq "merge base saved for phpBB $version" "$version" "$(in_data up1 'cat .phpbb-dist-base/VERSION')"
check_eq "forum page loads" 200 "$(http_code up1 '/viewforum.php?f=2')"
check_has "forum page uses the merged template" "admin edit: top" "$(docker exec "$(c up1)" curl -s 'http://localhost:8080/viewforum.php?f=2')"

echo "Backup written before the upgrade"
zip=$(docker exec "$(c up1)" sh -c 'ls /opt/phpbb/backups/*.zip')
check_has "named after the old version" "/opt/phpbb/backups/phpbb-$LEGACY_PHPBB_VERSION-" "$zip"
check "zip is valid" docker exec "$(c up1)" unzip -tq "$zip"
check_eq "holds the database as it was before the upgrade" "$LEGACY_PHPBB_VERSION" \
  "$(docker exec "$(c up1)" sh -c "cd /tmp && unzip -oq '$zip' phpbb.sqlite && sqlite3 phpbb.sqlite \"SELECT config_value FROM phpbb_config WHERE config_name='version'\"")"
check_eq "holds config.php and the attachments" 2 \
  "$(docker exec "$(c up1)" sh -c "unzip -l '$zip' | grep -cE ' phpbb/(config\.php|files/test_attachment)\$'")"
check_eq "leaves out backups and the merge base" 0 "$(docker exec "$(c up1)" sh -c "unzip -l '$zip' | grep -cE ' backups/|phpbb-dist-base'")"

echo "Restarts"
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sleep 1
docker restart "$(c up1)" >/dev/null
wait_up up1
after=$(docker logs --since "$since" "$(c up1)" 2>&1)
check_lacks "nothing is merged or migrated again" "Merging" "$after"
check_eq "no second backup" 1 "$(docker exec "$(c up1)" sh -c 'ls /opt/phpbb/backups | wc -l' | tr -d ' ')"
check_has "warning repeats while the flag file exists" "SECURITY WARNING" "$after"
docker exec "$(c up1)" rm "$DATA/.change-admin-password"
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sleep 1
docker restart "$(c up1)" >/dev/null
wait_up up1
check_lacks "deleting the flag silences the warning" "SECURITY WARNING" "$(docker logs --since "$since" "$(c up1)" 2>&1)"
check_fails "and the flag is not re-created" in_data up1 "test -e .change-admin-password"

echo "Board from this image at phpBB $old_version, with admin edits to a template line and an image phpBB changed"
start old2 "$OLD_IMAGE" -v "$(vol board2):/opt/phpbb" -e PHPBB_PASSWORD="$T_PASSWORD"
docker stop "$(c old2)" >/dev/null
on_volume board2 "sed -i 's/class=\"row-item-link\"><\/a><!-- ENDIF -->/class=\"row-item-link admin-edit\"><\/a><!-- ENDIF -->/' $DATA/$VF"
# phpBB hasn't changed a stock image lately, so stand in for one by changing the
# image's copy in the merge base; the NUL byte makes git treat it as binary
GIF=images/smilies/icon_e_wink.gif
on_volume board2 "printf 'GIF89a\000base' > $DATA/.phpbb-dist-base/$GIF && printf 'GIF89a\000admin' > $DATA/$GIF"
before=$(on_volume board2 "md5sum $DATA/$VF")
start up2 "$IMAGE" -v "$(vol board2):/opt/phpbb"
check_eq "upgrade stops with an error" 1 "$(exit_code up2)"
check_has "names the conflicting file" "$VF was changed on the volume and in phpBB $version, and the changes conflict" "$(logs up2)"
check_has "prints the conflict" "<<<<<<< volume" "$(logs up2)"
check_has "names the image git can't merge, and why" "$GIF was changed on the volume and in phpBB $version, and git can't merge it: error: Cannot merge binary files" "$(logs up2)"
check_eq "database untouched" "$old_version" "$(db_version_on board2)"
check_eq "file untouched" "$before" "$(on_volume board2 "md5sum $DATA/$VF")"
check_fails "no backup written" on_volume board2 "test -e /opt/phpbb/backups"
check_eq "merge base still at phpBB $old_version" "$old_version" "$(on_volume board2 "cat $DATA/.phpbb-dist-base/VERSION")"
on_volume board2 "cp $DATA/.phpbb-dist-base/$VF $DATA/$VF && cp $DATA/.phpbb-dist-base/$GIF $DATA/$GIF"
start up2b "$IMAGE" -v "$(vol board2):/opt/phpbb"
check "after restoring phpBB's original file the upgrade succeeds" running up2b
check_eq "database upgraded to phpBB $version" "$version" "$(sqlite_version up2b)"

echo "Board from this image at phpBB $old_version, upgraded to $version, then downgraded"
start old3 "$OLD_IMAGE" -v "$(vol board3):/opt/phpbb" -e PHPBB_PASSWORD="$T_PASSWORD"
check_eq "merge base saved at install" "$old_version" "$(in_data old3 'cat .phpbb-dist-base/VERSION')"
docker stop "$(c old3)" >/dev/null
on_volume board3 "sed -i '1i <!-- admin edit: top -->' $DATA/$VF"
start new3 "$IMAGE" -v "$(vol board3):/opt/phpbb"
check "upgraded container is running" running new3
check_has "merged from the saved base" "from $old_version to $version" "$(logs new3)"
check_eq "database upgraded to phpBB $version" "$version" "$(sqlite_version new3)"
check "admin edit kept" in_data new3 "grep -q 'admin edit: top' $VF"
check "phpBB's change merged" in_data new3 "grep -q '$NEW_LINE' $VF"
check_eq "admin logs in" 2 "$(login new3 admin "$T_PASSWORD")"
docker stop "$(c new3)" >/dev/null
start down3 "$OLD_IMAGE" -v "$(vol board3):/opt/phpbb"
check_eq "the older image refuses to start" 1 "$(exit_code down3)"
check_has "because downgrades are not supported" "Downgrades are not supported" "$(logs down3)"
check_eq "database left at phpBB $version" "$version" "$(db_version_on board3)"

echo "Board from this image at phpBB $old_version, where writing a merged file fails"
start old4 "$OLD_IMAGE" -v "$(vol board4):/opt/phpbb" -e PHPBB_PASSWORD="$T_PASSWORD"
docker stop "$(c old4)" >/dev/null
on_volume board4 "chmod 555 $DATA/$(dirname $VF)"
start up4 "$IMAGE" -v "$(vol board4):/opt/phpbb"
check_eq "upgrade stops with an error" 1 "$(exit_code up4)"
check_has "names a file it could not write" "Could not write $DATA/$(dirname $VF)/" "$(logs up4)"
check_eq "database was already upgraded to phpBB $version" "$version" "$(db_version_on board4)"
check_eq "merge base not moved on" "$old_version" "$(on_volume board4 "cat $DATA/.phpbb-dist-base/VERSION")"
on_volume board4 "chmod 755 $DATA/$(dirname $VF)"
start up4b "$IMAGE" -v "$(vol board4):/opt/phpbb"
check "once it can write, the next boot finishes the upgrade" running up4b
check "phpBB's change merged" in_data up4b "grep -q '$NEW_LINE' $VF"
check_eq "merge base saved for phpBB $version" "$version" "$(in_data up4b 'cat .phpbb-dist-base/VERSION')"

echo "Same board, stopped while saving the merge base, after an admin edit to the line phpBB changed"
docker stop "$(c up4b)" >/dev/null
# Stopped between moving the old base aside and moving the new one in. Falling
# back to phpBB $LEGACY_PHPBB_VERSION's files would make this edit conflict.
on_volume board4 "cd $DATA && sed -i 's/class=\"row-item-link\"><\/a>{% endif %}/class=\"row-item-link admin-edit\"><\/a>{% endif %}/' $VF \
  && grep -q admin-edit $VF && mv .phpbb-dist-base .phpbb-dist-base.old"
start up4c "$IMAGE" -v "$(vol board4):/opt/phpbb"
check "container is running" running up4c
check_lacks "no conflict" "conflict" "$(logs up4c)"
check "admin edit kept" in_data up4c "grep -q 'row-item-link admin-edit' $VF"
check_eq "merge base back in place" "$version" "$(in_data up4c 'cat .phpbb-dist-base/VERSION')"
check_fails "previous base removed" in_data up4c "test -e .phpbb-dist-base.old"

finish
