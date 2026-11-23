# Third-party notices

## VLCKit

TuberView plays video with VLCKit 3.6.0 (and the libVLC engine inside it),
© VideoLAN and contributors.

- License: GNU Lesser General Public License, version 2.1. The full text is in
  [LICENSES/LGPL-2.1.txt](LICENSES/LGPL-2.1.txt).
- Source code: https://code.videolan.org/videolan/VLCKit
- The exact build used is downloaded from VideoLAN by
  [`scripts/fetch-vlckit.sh`](scripts/fetch-vlckit.sh) and checked against a
  fixed SHA-256 checksum.
- VLCKit is included unmodified, as a separate framework at
  `TuberView.app/Contents/Frameworks/VLCKit.framework`. You may replace it with
  your own build of VLCKit.

## TMDB

The optional Top 10 rows use the TMDB API. This product uses the TMDB API but
is not endorsed or certified by TMDB.
