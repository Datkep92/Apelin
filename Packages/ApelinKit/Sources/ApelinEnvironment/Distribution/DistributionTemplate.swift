import Foundation

/// The files a package repository starts with, after owngoal-dev/owngoal-packages
/// (OwnGoal's own source) trimmed to what one person's repository needs: the
/// packages committed in `debs/`, indexed by GitHub Actions into `Packages`,
/// `Packages.xz` and `Release` with apt-ftparchive and published to GitHub
/// Pages on every push to the repository's branch. `__REPOSITORY__`,
/// `__SOURCE_URL__` and `__BRANCH__` are the repository's `owner/name`, its
/// Pages address and the branch its packages are pushed to.
enum DistributionTemplate {
    /// What a repository must have for Apelin to call it one; a link adds
    /// whatever of the template it lacks.
    static let workflowPath = ".github/workflows/update-repository.yml"

    static func files(
        repository: String,
        sourceURL: String,
        branch: String,
    ) -> [(path: String, contents: String, executable: Bool)] {
        let fill = { (text: String) in
            text.replacingOccurrences(of: "__REPOSITORY__", with: repository)
                .replacingOccurrences(of: "__SOURCE_URL__", with: sourceURL)
                .replacingOccurrences(of: "__BRANCH__", with: branch)
        }
        return [
            (workflowPath, fill(workflow), false),
            ("scripts/update-repository.sh", updateScript, true),
            ("index.html", fill(indexPage), false),
            ("README.md", fill(readme), false),
            ("debs/README.md", debsReadme, false),
            ("depictions/README.md", depictionsReadme, false),
            ("sileo-featured.json", featured, false),
            (".gitignore", gitignore, false),
        ]
    }

    static let workflow = """
    name: Build and Deploy APT Repository

    on:
      push:
        branches:
          - __BRANCH__
        paths:
          - ".github/workflows/update-repository.yml"
          - "debs/**"
          - "depictions/**"
          - "scripts/update-repository.sh"
          - "CydiaIcon.png"
          - "index.html"
          - "sileo-featured.json"
      workflow_dispatch:

    permissions:
      contents: read

    concurrency:
      group: github-pages
      cancel-in-progress: true

    jobs:
      build:
        runs-on: ubuntu-latest
        steps:
          - name: Check out repository
            uses: actions/checkout@v4

          - name: Install repository tools
            run: |
              sudo apt-get update
              sudo apt-get install --yes apt-utils xz-utils

          - name: Build repository
            env:
              REPOSITORY_NAME: ${{ github.event.repository.name }}
              REPOSITORY_OWNER: ${{ github.repository_owner }}
            run: ./scripts/update-repository.sh

          - name: Configure GitHub Pages
            uses: actions/configure-pages@v5

          - name: Upload GitHub Pages artifact
            uses: actions/upload-pages-artifact@v3
            with:
              path: _site

      deploy:
        needs: build
        runs-on: ubuntu-latest
        permissions:
          pages: write
          id-token: write
        environment:
          name: github-pages
          url: ${{ steps.deployment.outputs.page_url }}
        steps:
          - name: Deploy to GitHub Pages
            id: deployment
            uses: actions/deploy-pages@v4

    """

    static let updateScript = #"""
    #!/usr/bin/env bash
    # Indexes debs/ into Packages, Packages.xz and Release and writes the site
    # GitHub Pages serves to _site/. Run by the workflow on every push to
    # main; on Debian or Ubuntu it runs the same by hand.
    set -euo pipefail

    repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
    cd "$repository_root"

    for command_name in apt-ftparchive xz; do
      if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Missing required command: $command_name" >&2
        exit 69
      fi
    done

    name="${REPOSITORY_NAME:-$(basename "$repository_root")}"
    owner="${REPOSITORY_OWNER:-$name}"
    work_dir="$(mktemp -d "$repository_root/.repo-build.XXXXXX")"
    trap 'rm -rf -- "$work_dir"' EXIT
    site_dir="$work_dir/site"
    mkdir -p "$site_dir"

    shopt -s nullglob
    packages=(debs/*.deb)
    shopt -u nullglob

    # Running from the root keeps each Filename relative: debs/<file>.deb.
    if ((${#packages[@]} > 0)); then
      apt-ftparchive packages debs > "$work_dir/Packages"
    else
      : > "$work_dir/Packages"
    fi

    # Sileo files a package with no Section under nothing; refuse it here.
    awk '
      BEGIN { RS = ""; FS = "\n" }
      {
        package = ""; section = ""
        for (field = 1; field <= NF; field++) {
          if ($field ~ /^Package: /) package = substr($field, 10)
          if ($field ~ /^Section: /) section = substr($field, 10)
        }
        if (package != "" && section == "") {
          printf "Package %s has no Section field, which Sileo needs.\n", package > "/dev/stderr"
          exit 1
        }
      }
    ' "$work_dir/Packages"

    xz -9e -c "$work_dir/Packages" > "$work_dir/Packages.xz"
    mkdir -p "$work_dir/indexes"
    cp "$work_dir/Packages" "$work_dir/Packages.xz" "$work_dir/indexes/"

    # Release is written beside the indexes, never among them, so it does
    # not hash itself.
    apt-ftparchive \
      -o APT::FTPArchive::Release::Origin="$owner" \
      -o APT::FTPArchive::Release::Label="$name" \
      -o APT::FTPArchive::Release::Suite="stable" \
      -o APT::FTPArchive::Release::Version="1.0" \
      -o APT::FTPArchive::Release::Codename="$name" \
      -o APT::FTPArchive::Release::Architectures="iphoneos-arm iphoneos-arm64 iphoneos-arm64e" \
      -o APT::FTPArchive::Release::Components="main" \
      -o APT::FTPArchive::Release::Description="Packages from $owner" \
      release "$work_dir/indexes" > "$work_dir/Release"

    if ((${#packages[@]} > 0)); then
      mkdir -p "$site_dir/debs"
      cp "${packages[@]}" "$site_dir/debs/"
    fi
    for file in index.html CydiaIcon.png sileo-featured.json; do
      if [[ -f "$file" ]]; then
        cp "$file" "$site_dir/"
      fi
    done
    if [[ -d depictions ]]; then
      cp -R depictions "$site_dir/depictions"
    fi
    cp "$work_dir/Packages" "$work_dir/Packages.xz" "$work_dir/Release" "$site_dir/"
    # Pages runs no Jekyll over the site.
    touch "$site_dir/.nojekyll"

    rm -rf -- "$repository_root/_site"
    mv "$site_dir" "$repository_root/_site"
    echo "Built the APT repository in _site/ (${#packages[@]} packages)"

    """#

    static let indexPage = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>__REPOSITORY__</title>
    <style>
    :root { color-scheme: light dark; --muted: #6e6e73; --line: rgba(127, 127, 127, 0.25); }
    body { margin: 0; font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
    main { max-width: 640px; margin: 0 auto; padding: 32px 16px 48px; }
    h1 { font-size: 28px; margin: 0 0 4px; }
    p { margin: 0 0 16px; color: var(--muted); }
    code { display: block; padding: 12px; border: 1px solid var(--line); border-radius: 10px; word-break: break-all; }
    .actions { display: flex; flex-wrap: wrap; gap: 8px; margin: 16px 0 32px; }
    .actions a { padding: 8px 14px; border-radius: 999px; background: #0a84ff; color: #fff; text-decoration: none; }
    li { list-style: none; padding: 12px 0; border-bottom: 1px solid var(--line); }
    ul { padding: 0; }
    li span { color: var(--muted); }
    </style>
    </head>
    <body>
    <main>
    <h1>__REPOSITORY__</h1>
    <p>Add this source to your package manager:</p>
    <code id="source"></code>
    <div class="actions">
    <a id="sileo">Add to Sileo</a>
    <a id="zebra">Add to Zebra</a>
    </div>
    <ul id="packages"></ul>
    </main>
    <script>
    const source = new URL(".", location.href).href;
    document.getElementById("source").textContent = source;
    document.getElementById("sileo").href = "sileo://source/" + source;
    document.getElementById("zebra").href = "zbra://sources/add/" + source;
    fetch("Packages").then(response => response.ok ? response.text() : "").then(text => {
      const newest = new Map();
      for (const block of text.split(/\\n\\n+/)) {
        const fields = {};
        for (const line of block.split("\\n")) {
          const match = /^([A-Za-z-]+): (.*)$/.exec(line);
          if (match) fields[match[1]] = match[2];
        }
        if (fields.Package) newest.set(fields.Package, fields);
      }
      const list = document.getElementById("packages");
      for (const fields of newest.values()) {
        const item = document.createElement("li");
        const name = document.createElement("strong");
        name.textContent = (fields.Name || fields.Package) + " " + (fields.Version || "");
        const description = document.createElement("span");
        description.textContent = fields.Description ? " — " + fields.Description : "";
        item.append(name, description);
        list.append(item);
      }
    });
    </script>
    </body>
    </html>

    """

    static let readme = """
    # __REPOSITORY__

    An APT source for jailbroken iOS, published with Apelin.

    Add `__SOURCE_URL__` in Sileo, Zebra or Irisin.

    ## How it works

    - Packages are the `.deb` files in `debs/`, named
      `<Package>_<Version>_<Architecture>.deb`. Apelin's Distribute… page
      publishes a release build here; a `.deb` pushed by hand works the same.
    - On every push to `__BRANCH__`, `.github/workflows/update-repository.yml` runs
      `scripts/update-repository.sh`, which indexes `debs/` into `Packages`,
      `Packages.xz` and `Release`, and publishes the site to GitHub Pages.
      Never commit those indexes or `_site/`.
    - `depictions/<package id>/` holds a package's depiction, icon and
      banner; `sileo-featured.json` the banners Sileo shows at the top of the
      source; `CydiaIcon.png`, when present, the source's icon.

    Pages may serve the previous index for up to ten minutes after a push.

    """

    static let debsReadme = """
    # Packages

    Put one `.deb` per package version here, named
    `<Package>_<Version>_<Architecture>.deb`, and push.

    Each package's control file needs these fields:

    ```debcontrol
    Package: com.example.tweak
    Name: Example Tweak
    Version: 1.0.0
    Architecture: iphoneos-arm64
    Description: A short description.
    Maintainer: Your Name <you@example.com>
    Author: Your Name <you@example.com>
    Section: Tweaks
    ```

    `Section` is Sileo's category (Tweaks, Applications, Utilities,
    Themes…); the index refuses a package without it. `Depiction`,
    `SileoDepiction` and `Icon` may point into `depictions/<package id>/`.
    Rootless packages are `iphoneos-arm64`, roothide ones `iphoneos-arm64e`.

    """

    static let depictionsReadme = """
    # Depictions

    Optional, one folder per package id: `index.html` (the web depiction),
    `depiction.json` (Sileo's native depiction), `icon.png` and
    `banner.png`. They are published at
    `<source>/depictions/<package id>/…`.

    """

    static let featured = """
    {
      "class": "FeaturedBannersView",
      "itemSize": "{263, 148}",
      "itemCornerRadius": 10,
      "banners": []
    }

    """

    static let gitignore = """
    .DS_Store
    .repo-build.*
    /_site/
    /Packages
    /Packages.*
    /Release
    /Release.gpg
    /InRelease

    """
}
