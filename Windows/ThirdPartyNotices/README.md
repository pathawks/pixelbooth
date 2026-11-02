# Third-party components

- **Windows App SDK** is supplied by Microsoft via NuGet. Its package contains
  Microsoft license and third-party notices.
- **MediaFoundation.NetCore 2024.5.10** provides Media Foundation interop.
  The upstream project offers BSD or LGPL licensing; the BSD text is included
  as `MediaFoundationNet-BSD.txt`. Source:
  https://github.com/visioforge/MediaFoundationNet
- **LibHeif.Native.Runtime 1.20.2** provides `libheif.dll`, dynamically loaded
  by this application. Its NuGet metadata identifies LGPL-3.0-or-later and its
  README says the binary includes libheif, libde265, dav1d, and libaom.
  `libheif-COPYING.txt`, `dav1d-COPYING.txt`, and `libaom-LICENSE.txt` contain
  the corresponding upstream notices; libde265's upstream license is included
  in the libheif LGPL/GPL text. Upstream source locations are
  https://github.com/strukturag/libheif/tree/v1.20.2,
  https://github.com/strukturag/libde265,
  https://code.videolan.org/videolan/dav1d, and
  https://aomedia.googlesource.com/aom/.

**Before redistributing a Windows binary**, replace or audit the native runtime:
the package's declared source/build repository
`https://github.com/borka-s/LibHeif.Native.Runtime` was unavailable when checked,
so the precise bundled codec versions, build configuration, and corresponding
source cannot be established from it. The current package is useful for local
development and testing but is not a reproducible release dependency. Review
the native libraries' notices and license obligations for the actual build.
