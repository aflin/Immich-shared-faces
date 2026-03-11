# Immich Shared Faces Patch

This patch was written by Claude (Anthropic) to modify Immich so that users
viewing shared albums can see the album owner's facial recognition data —
person names, face bounding boxes, thumbnails, and search.

## Compatibility

Tested against **Immich v2.5.6** only. Other versions may have different
internal code and the patch may fail or behave unexpectedly.

## Usage

Place `patch-shared-faces.sh` in the same directory as your Immich
`docker-compose.yml`, then run:

```bash
./patch-shared-faces.sh
```

The script expects the Immich containers to be running. It is idempotent —
it detects already-applied patches and skips them.

## Persistence

The patches modify files inside the Docker container. They are **lost** whenever
the container is recreated, which happens on:

- `docker compose down && docker compose up -d`
- System reboot (containers are recreated from the clean image)
- `docker compose pull` (image update)

To persist across restarts, either:

- **Re-run the script after each start**, e.g. via a cron job:
  ```
  @reboot sleep 30 && /path/to/patch-shared-faces.sh >> /path/to/patch.log 2>&1
  ```
- **Commit the running container as a new image** with `docker commit`, then
  update `docker-compose.yml` to use that image instead of the official one.

## What changes after applying the patch

- **Face tags visible in shared albums.** When viewing photos in an album
  shared with you, you will see the album owner's tagged people — names and
  face bounding boxes — on each photo.

- **Shared people appear in the People page.** People from shared album
  owners are listed alongside your own. Shared people are marked with a
  **★** after their name (e.g. "John Smith ★") to distinguish them from
  your own tags.

- **Shared people are searchable.** You can find shared people in the search
  bar and filter photos by them.

- **Clicking a shared person shows their photos.** The person detail page
  works for shared people and displays their photos from the shared album.

## Known limitations

- **Duplicate names.** If you and the album owner have both tagged the same
  person, they will appear twice — once without a star (yours) and once
  with a ★ (theirs). These are separate entries from separate libraries.

- **Shared people are read-only.** You cannot edit, rename, merge, or
  reassign faces for shared people (the ones marked with ★). Attempting
  to do so will result in an error.

- **Scope of visibility.** When searching by a shared person or viewing
  their detail page, all of the album owner's photos containing that
  person are shown — not just the ones in the specific shared album.
