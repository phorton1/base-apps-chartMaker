# chartMaker Windows Installer Releases

The downloadable **Windows installer** for chartMaker lives on this repository's
[**Releases**](https://github.com/phorton1/base-apps-chartMaker/releases) page, not in this
folder: the installer exe is a GitHub Release asset, so this repo stays text-only and lean.

chartMaker is *pure Perl / wxPerl*. The installer bundles it with a private **ActivePerl
5.12** via the ancient **Cava Packager 2.0** -- the only tool that still packages this
Perl/wx stack as a standalone Windows exe. The full build method is arcane and effectively
unpublishable, but **all** source (chartMaker and `Pub::`) is here on GitHub and is
guaranteed free of malware or adware.

> **Pre-release.** chartMaker is below 1.0, so the `.tsd`, `.region` and `.RCT` formats may
> still change between releases and a release is throwaway. See
> [Deployment](../docs/deployment.md#version-scheme).

This is a release LOG, not a changelog. For what changed between any two releases the git
history is authoritative: `git log chartMaker<older>..chartMaker<newer>`.

## Releases

| date | version | notes |
| ---- | ------- | ----- |

Each release is the same tag `chartMaker<version>` stamped across the four repositories it
was built from, so `git checkout chartMaker<version>` in each reconstructs exactly the
source it came from. **The tags are the provenance and no commit hashes are recorded here** -
a written list of hashes is a second account of what the tags already say, transcribed by
hand at the one moment when care is most expensive.

<!-- Entry template (newest first, added when a release is cut).

### chartMaker0.1.0 -- YYYY-MM-DD (pre-release)

<a few lines of highlights, or nothing at all - the table row is the record>

No SHA block: the `chartMaker0.1.0` tag in each of the four repositories is the provenance.
-->
