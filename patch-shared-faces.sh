#!/bin/bash
#
# patch-shared-faces.sh
#
# Patches an Immich Docker install so that users viewing shared albums
# can see the album owner's facial recognition data (person names,
# face bounding boxes, and person thumbnails).
#
# Tested against Immich v2.5.6. Will warn if a different version is detected.
#
# Changes made:
#   1. Backend: Don't strip people data from assets viewed by shared album members
#   2. Backend: Allow shared album members to fetch person thumbnails
#   3. Frontend: Show the people section for non-owners viewing shared albums
#   4. Frontend: Make person links display-only for non-owners
#   5. Frontend: Hide face edit buttons (+, pencil, show hidden) for non-owners
#   6. Backend: Make people from shared albums searchable in search box
#   7. Backend: Include shared album people in the People listing
#   8. Remove precompressed frontend files so modified JS is served
#   9. Backend: Include shared album owner assets in person search results
#  10. Backend: Allow viewing shared person detail pages (getById, getStatistics, timeline)
#
# Usage:
#   ./patch-shared-faces.sh [container_name]
#
# Default container name is "immich_server".

set -euo pipefail

CONTAINER="${1:-immich_server}"
EXPECTED_VERSION="2.5.6"

echo "=== Immich Shared Faces Patch ==="
echo ""

# Check container is running
if ! docker inspect --format='{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
    echo "ERROR: Container '$CONTAINER' is not running."
    exit 1
fi

# Check version
VERSION=$(docker exec "$CONTAINER" curl -sf http://localhost:2283/api/server/version 2>/dev/null || echo "")
if [ -z "$VERSION" ]; then
    echo "WARNING: Could not determine Immich version. Proceeding anyway."
elif echo "$VERSION" | python3 -c "
import sys, json
v = json.load(sys.stdin)
print(f\"{v['major']}.{v['minor']}.{v['patch']}\")
" 2>/dev/null | grep -qx "$EXPECTED_VERSION"; then
    echo "Immich version $EXPECTED_VERSION detected. OK."
else
    DETECTED=$(echo "$VERSION" | python3 -c "import sys,json; v=json.load(sys.stdin); print(f\"{v['major']}.{v['minor']}.{v['patch']}\")" 2>/dev/null || echo "unknown")
    echo "WARNING: Expected Immich v$EXPECTED_VERSION but detected v$DETECTED."
    echo "         This patch may not work correctly on this version."
    read -p "         Continue anyway? [y/N] " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

echo ""

# --- Patch 1: Backend - asset.service.js ---
echo "Patch 1: Allow people data in shared album asset responses..."

ASSET_SERVICE="/usr/src/app/server/dist/services/asset.service.js"

# Verify the original pattern exists
if docker exec "$CONTAINER" grep -q 'data.ownerId !== auth.user.id || auth.sharedLink' "$ASSET_SERVICE"; then
    docker exec "$CONTAINER" sed -i \
        's/if (data.ownerId !== auth.user.id || auth.sharedLink) {/if (auth.sharedLink) { \/\/ PATCHED: shared faces/' \
        "$ASSET_SERVICE"
    echo "  OK"
elif docker exec "$CONTAINER" grep -q '// PATCHED: shared faces' "$ASSET_SERVICE"; then
    echo "  Already patched, skipping."
else
    echo "  WARNING: Expected pattern not found in asset.service.js. Skipping."
fi

# --- Patch 2: Backend - person.service.js ---
echo "Patch 2: Allow shared album members to view person thumbnails..."

PERSON_SERVICE="/usr/src/app/server/dist/services/person.service.js"

# We need to comment out the requireAccess line inside getThumbnail only.
# The pattern: getThumbnail method followed by requireAccess with PersonRead
if docker exec "$CONTAINER" grep -q 'async getThumbnail' "$PERSON_SERVICE" && \
   ! docker exec "$CONTAINER" grep -q 'getThumbnail.*// PATCHED' "$PERSON_SERVICE"; then
    docker exec "$CONTAINER" sed -i '/async getThumbnail(auth, id) {/{
        s/async getThumbnail(auth, id) {/async getThumbnail(auth, id) { \/\/ PATCHED: shared faces/
        n
        s/.*await this.requireAccess.*PersonRead.*/        \/\/ requireAccess removed for shared album face thumbnails/
    }' "$PERSON_SERVICE"
    echo "  OK"
elif docker exec "$CONTAINER" grep -q 'getThumbnail.*// PATCHED' "$PERSON_SERVICE"; then
    echo "  Already patched, skipping."
else
    echo "  WARNING: Expected pattern not found in person.service.js. Skipping."
fi

# --- Patch 3: Frontend - detail panel chunk ---
echo "Patch 3: Show people section for non-owners in shared albums..."

# Find the chunk containing the isOwner gate for the people section.
# We search for the pattern: !ti.isSharedLink&&h(f)&&ot(ut)
# The chunk filename changes per version, so we find it dynamically.
CHUNK_FILE=$(docker exec "$CONTAINER" grep -rl '!ti.isSharedLink&&h(f)&&ot(ut)' /build/www/_app/immutable/chunks/ 2>/dev/null || echo "")

if [ -n "$CHUNK_FILE" ]; then
    # Remove the h(f)&& (isOwner) check from the people section gate
    docker exec "$CONTAINER" sed -i \
        's/!ti.isSharedLink&&h(f)&&ot(ut)/!ti.isSharedLink\&\&ot(ut)/g' \
        "$CHUNK_FILE"

    # Delete precompressed versions so the modified file is served
    docker exec "$CONTAINER" rm -f "${CHUNK_FILE}.br" "${CHUNK_FILE}.gz"

    echo "  OK (patched $CHUNK_FILE)"
elif docker exec "$CONTAINER" grep -rl '!ti.isSharedLink&&ot(ut)' /build/www/_app/immutable/chunks/ 2>/dev/null | grep -q .; then
    echo "  Already patched, skipping."
else
    echo "  WARNING: Could not find frontend chunk with expected pattern."
    echo "           The minified variable names may differ in this version."
fi

# --- Patch 4: Frontend - disable person link for non-owners ---
echo "Patch 4: Make person links display-only for non-owners..."

# The person link uses: ()=>sr.viewPerson(h(mt),{previousRoute:h(M)})
# We wrap it so non-owners get "#" instead of a person page link.
# This uses the same chunk file found in Patch 3.
# If Patch 3 didn't find it, try to find it by the viewPerson pattern.
if [ -z "$CHUNK_FILE" ]; then
    CHUNK_FILE=$(docker exec "$CONTAINER" grep -rl 'sr.viewPerson' /build/www/_app/immutable/chunks/ 2>/dev/null | head -1 || echo "")
fi

if [ -n "$CHUNK_FILE" ] && docker exec "$CONTAINER" grep -q '()=>sr.viewPerson(h(mt),{previousRoute:h(M)})' "$CHUNK_FILE"; then
    docker exec "$CONTAINER" sed -i \
        's/()=>sr.viewPerson(h(mt),{previousRoute:h(M)})/()=>h(f)?sr.viewPerson(h(mt),{previousRoute:h(M)}):"#"/g' \
        "$CHUNK_FILE"

    # Delete precompressed versions if they were regenerated
    docker exec "$CONTAINER" rm -f "${CHUNK_FILE}.br" "${CHUNK_FILE}.gz"

    echo "  OK"
elif [ -n "$CHUNK_FILE" ] && docker exec "$CONTAINER" grep -q 'h(f)?sr.viewPerson' "$CHUNK_FILE"; then
    echo "  Already patched, skipping."
else
    echo "  WARNING: Could not find viewPerson pattern in frontend chunk. Skipping."
fi

# --- Patch 5: Frontend - hide edit buttons for non-owners ---
echo "Patch 5: Hide face edit buttons for non-owners..."

# The people section has a button container div (show hidden, +, pencil).
# In minified code: var Pt=k(kt,2),Ot=b(Pt)
# We insert a style.display="none" when not owner: if(!h(f))Pt.style.display="none"
if [ -z "$CHUNK_FILE" ]; then
    CHUNK_FILE=$(docker exec "$CONTAINER" grep -rl 'show_hidden_people' /build/www/_app/immutable/chunks/ 2>/dev/null | head -1 || echo "")
fi

if [ -n "$CHUNK_FILE" ] && docker exec "$CONTAINER" grep -q 'var Pt=k(kt,2),Ot=b(Pt)' "$CHUNK_FILE"; then
    docker exec "$CONTAINER" sed -i \
        's/var Pt=k(kt,2),Ot=b(Pt)/var Pt=k(kt,2);if(!h(f))Pt.style.display="none";var Ot=b(Pt)/' \
        "$CHUNK_FILE"

    # Delete precompressed versions if they were regenerated
    docker exec "$CONTAINER" rm -f "${CHUNK_FILE}.br" "${CHUNK_FILE}.gz"

    echo "  OK"
elif [ -n "$CHUNK_FILE" ] && docker exec "$CONTAINER" grep -q 'if(!h(f))Pt.style.display' "$CHUNK_FILE"; then
    echo "  Already patched, skipping."
else
    echo "  WARNING: Could not find button container pattern in frontend chunk. Skipping."
fi

# --- Patch 6: Backend - make shared album people searchable ---
echo "Patch 6: Make people from shared albums searchable..."

SEARCH_SERVICE="/usr/src/app/server/dist/services/search.service.js"

if docker exec "$CONTAINER" grep -q 'async searchPerson' "$SEARCH_SERVICE" && \
   ! docker exec "$CONTAINER" grep -q 'searchPerson.*// PATCHED' "$SEARCH_SERVICE"; then
    docker exec "$CONTAINER" sed -i '/async searchPerson(auth, dto) {/{
        N;N;
        s#async searchPerson(auth, dto) {\n        const people = await this.personRepository.getByName(auth.user.id, dto.name, { withHidden: dto.withHidden });\n        return people.map((person) => (0, person_dto_1.mapPerson)(person));#async searchPerson(auth, dto) { // PATCHED: shared faces\n        const people = await this.personRepository.getByName(auth.user.id, dto.name, { withHidden: dto.withHidden });\n        const sharedOwnerIds = await this.albumRepository.getShared(auth.user.id).then(albums => [...new Set(albums.map(a => a.ownerId).filter(id => id !== auth.user.id))]);\n        const sharedPeople = [];\n        for (const ownerId of sharedOwnerIds) { const p = await this.personRepository.getByName(ownerId, dto.name, { withHidden: false }); sharedPeople.push(...p); }\n        for (const p of sharedPeople) { p.name = (p.name || "") + " ★"; }\n        return [...people, ...sharedPeople].map((person) => (0, person_dto_1.mapPerson)(person));#
    }' "$SEARCH_SERVICE"
    echo "  OK"
elif docker exec "$CONTAINER" grep -q 'searchPerson.*// PATCHED' "$SEARCH_SERVICE"; then
    echo "  Already patched, skipping."
else
    echo "  WARNING: Expected pattern not found in search.service.js. Skipping."
fi

# --- Patch 7: Backend - include shared album people in People listing ---
echo "Patch 7: Include shared album people in People listing..."

# The getAll method in person.service.js only returns people owned by the current user.
# We add a second query for people owned by users who have shared albums with the current user.
if docker exec "$CONTAINER" grep -q 'getNumberOfPeople(auth.user.id);' "$PERSON_SERVICE" && \
   ! docker exec "$CONTAINER" grep -q 'PATCHED: shared faces - include people' "$PERSON_SERVICE"; then
    docker exec "$CONTAINER" sed -i '/const { total, hidden } = await this.personRepository.getNumberOfPeople(auth.user.id);/{
        s#const { total, hidden } = await this.personRepository.getNumberOfPeople(auth.user.id);#const { total, hidden } = await this.personRepository.getNumberOfPeople(auth.user.id);\n        // PATCHED: shared faces - include people from shared album owners\n        const sharedOwnerIds = await this.albumRepository.getShared(auth.user.id).then(albums => [...new Set(albums.map(a => a.ownerId).filter(id => id !== auth.user.id))]);\n        for (const ownerId of sharedOwnerIds) { const { items: sharedItems } = await this.personRepository.getAllForUser({ take: 1000, skip: 0 }, ownerId, { minimumFaceCount: machineLearning.facialRecognition.minFaces, withHidden: false, closestFaceAssetId }); for (const p of sharedItems) { p.name = (p.name || "") + " ★"; } items.push(...sharedItems); }#
    }' "$PERSON_SERVICE"
    echo "  OK"
elif docker exec "$CONTAINER" grep -q 'PATCHED: shared faces - include people' "$PERSON_SERVICE"; then
    echo "  Already patched, skipping."
else
    echo "  WARNING: Expected pattern not found in person.service.js. Skipping."
fi

# --- Patch 9: Backend - include shared album owner assets in person search ---
echo "Patch 9: Include shared album owner assets in person search results..."

SEARCH_SERVICE="/usr/src/app/server/dist/services/search.service.js"

# When searching by personId, the query only returns assets owned by the current user.
# We need to also include assets owned by shared album owners so their photos appear.
if docker exec "$CONTAINER" grep -q 'getUserIdsToSearch(auth)' "$SEARCH_SERVICE" && \
   ! docker exec "$CONTAINER" grep -q 'PATCHED: shared faces - search' "$SEARCH_SERVICE"; then
    docker exec "$CONTAINER" perl -0777 -i -pe \
        's/(const userIds = await this\.getUserIdsToSearch\(auth\);\n)(\s+const \{ hasNextPage, items \} = await this\.searchRepository\.searchMetadata)/$1        if (dto.personIds \&\& dto.personIds.length > 0) { const sharedOwnerIds = await this.albumRepository.getShared(auth.user.id).then(albums => [...new Set(albums.map(a => a.ownerId).filter(id => id !== auth.user.id))]); for (const oid of sharedOwnerIds) { if (!userIds.includes(oid)) userIds.push(oid); } } \/\/ PATCHED: shared faces - search\n$2/' \
        "$SEARCH_SERVICE"
    echo "  OK"
elif docker exec "$CONTAINER" grep -q 'PATCHED: shared faces - search' "$SEARCH_SERVICE"; then
    echo "  Already patched, skipping."
else
    echo "  WARNING: Expected pattern not found in search.service.js for metadata search. Skipping."
fi

# --- Patch 10: Backend - allow viewing shared person detail pages ---
echo "Patch 10: Allow viewing shared person detail pages..."

TIMELINE_SERVICE="/usr/src/app/server/dist/services/timeline.service.js"

# 10a: Remove requireAccess from getById in person.service.js
if docker exec "$CONTAINER" grep -q 'async getById(auth, id)' "$PERSON_SERVICE" && \
   ! docker exec "$CONTAINER" grep -q 'getById.*// PATCHED' "$PERSON_SERVICE"; then
    docker exec "$CONTAINER" sed -i '/async getById(auth, id) {/{
        s/async getById(auth, id) {/async getById(auth, id) { \/\/ PATCHED: shared faces - getById/
        n
        s/.*await this.requireAccess.*PersonRead.*/        \/\/ requireAccess removed for shared album person viewing/
    }' "$PERSON_SERVICE"
    echo "  OK (getById)"
elif docker exec "$CONTAINER" grep -q 'getById.*// PATCHED' "$PERSON_SERVICE"; then
    echo "  Already patched (getById), skipping."
else
    echo "  WARNING: Expected pattern not found for getById. Skipping."
fi

# 10b: Remove requireAccess from getStatistics in person.service.js
if docker exec "$CONTAINER" grep -q 'async getStatistics(auth, id)' "$PERSON_SERVICE" && \
   ! docker exec "$CONTAINER" grep -q 'getStatistics.*// PATCHED' "$PERSON_SERVICE"; then
    docker exec "$CONTAINER" sed -i '/async getStatistics(auth, id) {/{
        s/async getStatistics(auth, id) {/async getStatistics(auth, id) { \/\/ PATCHED: shared faces - getStatistics/
        n
        s/.*await this.requireAccess.*PersonRead.*/        \/\/ requireAccess removed for shared album person viewing/
    }' "$PERSON_SERVICE"
    echo "  OK (getStatistics)"
elif docker exec "$CONTAINER" grep -q 'getStatistics.*// PATCHED' "$PERSON_SERVICE"; then
    echo "  Already patched (getStatistics), skipping."
else
    echo "  WARNING: Expected pattern not found for getStatistics. Skipping."
fi

# 10c: Include shared album owner IDs in timeline queries when viewing a person
if docker exec "$CONTAINER" grep -q 'return { \.\.\.options, userIds };' "$TIMELINE_SERVICE" && \
   ! docker exec "$CONTAINER" grep -q 'PATCHED: shared faces' "$TIMELINE_SERVICE"; then
    docker exec "$CONTAINER" sed -i \
        's/return { \.\.\.options, userIds };/if (options.personId \&\& userIds) { const sharedOwnerIds = await this.albumRepository.getShared(auth.user.id).then(albums => [...new Set(albums.map(a => a.ownerId).filter(id => id !== auth.user.id))]); for (const oid of sharedOwnerIds) { if (!userIds.includes(oid)) userIds.push(oid); } } \/\/ PATCHED: shared faces - timeline\n        return { ...options, userIds };/' \
        "$TIMELINE_SERVICE"
    echo "  OK (timeline)"
elif docker exec "$CONTAINER" grep -q 'PATCHED: shared faces' "$TIMELINE_SERVICE"; then
    echo "  Already patched (timeline), skipping."
else
    echo "  WARNING: Expected pattern not found in timeline.service.js. Skipping."
fi

# --- Patch 8: Disable immutable caching for patched assets ---
echo "Patch 8: Disable immutable caching so browsers fetch patched files..."

APP_COMMON="/usr/src/app/server/dist/app.common.js"

if docker exec "$CONTAINER" grep -q "max-age=31536000,immutable" "$APP_COMMON"; then
    docker exec "$CONTAINER" sed -i \
        "s/res.setHeader('cache-control', 'public,max-age=31536000,immutable')/res.setHeader('cache-control', 'no-cache')/" \
        "$APP_COMMON"
    echo "  OK"
elif docker exec "$CONTAINER" grep -q "no-cache" "$APP_COMMON"; then
    echo "  Already patched, skipping."
else
    echo "  WARNING: Expected cache-control pattern not found. Skipping."
fi

# --- Restart the server process ---
echo ""
echo "Restarting Immich server process..."
docker exec "$CONTAINER" /bin/bash -c 'kill 1' 2>/dev/null || true

# Wait for it to come back
for i in $(seq 1 30); do
    sleep 1
    if docker exec "$CONTAINER" curl -sf http://localhost:2283/api/server/version > /dev/null 2>&1; then
        echo "  Server is back up."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "  WARNING: Server did not respond within 30 seconds."
        echo "           Check: docker logs $CONTAINER"
    fi
done

echo ""
echo "=== Patch complete ==="
echo ""
echo "Notes:"
echo "  - These changes live inside the container and will be LOST on"
echo "    'docker compose down' or 'docker compose pull'."
echo "  - After updating Immich, re-run this script."
echo "  - Users may need to clear browser cache to see the frontend change."
echo "  - A HARD REFRESH MAY NOT BE SUFFICIENT.  Clear site data if necessary."
echo "  - For the frontend patch, the minified variable names may change"
echo "    between Immich versions. If Patch 3 warns, the script needs"
echo "    updating for the new version."
