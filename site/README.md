# Mountfd landing page

Static HTML with compiled Tailwind CSS. No browser JavaScript or external fonts.

Build and preview from this directory (Node.js 24 and Python 3):

```sh
npm ci
npm run build
python3 -m http.server 8000 --directory dist
```

Open <http://localhost:8000>. Edit `index.html` or `styles.css`, then rebuild.
`dist/` is generated and is not committed. Links to local assets are relative,
so the site also works under the `/mountfd/` GitHub Pages path.

## Publish

In the repository's **Settings → Pages → Build and deployment**, select
**GitHub Actions** as the source. Merge these files into `main`; the
`GitHub Pages` workflow builds and deploys changes to `site/`. It can also be
run manually. Pull requests only build the site.

Expected URL: <https://ydah.github.io/mountfd/>.

Deployment follows GitHub's [custom workflow documentation](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).
