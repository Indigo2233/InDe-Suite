# Distribution notice

This repository contains the InDe-Suite PixInsight integration source code, build
automation, documentation, and tests.

The following items are intentionally excluded from Git history:

- ONNX model files and generated model-analysis artifacts
- application runtimes and generated build files
- PixInsight `.xssk` private signing keys
- signatures created with a Local Signing Identity
- generated binaries and build caches

The InDeConv, InDeNoise, and InDeStars models are developed by the project owner and
may be distributed in official InDe-Suite GitHub Release assets. The release packager
requires an explicit distribution confirmation. Product names and trademarks belong
to their respective owners.

A module distributed for installation on arbitrary PixInsight licenses requires a
valid Certified PixInsight Developer code signature. The Local Signing Edition ships
an unsigned module binary; each user generates a signature with their own PixInsight
Local Signing Identity before installation.

macOS modules carry an Apple ad-hoc code signature for Mach-O integrity. The
PixInsight Local Signing Identity is a separate requirement. Apple Developer ID
notarization is not provided. Bundled Python and Python packages retain their
upstream license files; the complete PCL legal notices are included in Mac packages.

This product is based on software from the PixInsight project, developed by
Pleiades Astrophoto and its contributors (https://pixinsight.com/).
