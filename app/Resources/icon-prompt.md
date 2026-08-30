# Vault app icon — how it was made, and how to remake it

The icon is a two-step job on purpose. An image model draws the *symbol*; a
script places it on the *geometry*. Models are good at shape language and bad at
the 824-in-1024 squircle Apple actually uses, so we never let one decide the
frame.

## Step 1 — generate the symbol

Model: `google/gemini-3.1-flash-image` on OpenRouter — this is the id behind the
name "Nano Banana 2". Send it as a chat completion with
`"modalities": ["image", "text"]`; the image comes back in
`choices[0].message.images[0].image_url.url`, either a `data:` URL to base64-decode
or an https URL to fetch. The key lives in the repo's `.env` as `OPENROUTER_API_KEY`.

The prompt is in two halves. The preamble is fixed and does the disciplining —
it is what keeps the model from adding the glow and the drop shadow it wants to add:

> Flat vector app icon artwork, rendered as a perfectly square image, full-bleed
> solid background of color #100F0F (near-black). One single symbol, perfectly
> centred, drawn in solid #3AA99F (muted teal). The symbol occupies about 46% of
> the canvas width, leaving generous empty margin all around. Absolutely flat: no
> gradient, no glow, no drop shadow, no 3D, no bevel, no highlight, no texture, no
> reflection, no outline stroke of a different colour. No text, no letters, no
> numbers. Geometric precision, crisp mathematical edges, even optical weight,
> thick enough strokes to stay legible when scaled down to 16 pixels. Style
> reference: Apple system symbol, Linear app iconography.

The second half is the symbol itself. The one that shipped:

> The symbol is a single bookmark ribbon: a vertical rectangle with a clean
> triangular notch cut into its bottom edge, corners subtly rounded. Solid filled
> shape, one piece, nothing else in the image.

Only the background colour and the symbol sentence matter to the script that
follows — it re-reads the teal as a mask and throws the rest of the frame away.

## Step 2 — place it

`make-icon.py` in this folder does the geometry, and the geometry is the part
that stops an icon looking homemade:

- **The tile is a superellipse**, `|x|^n + |y|^n = 1` at `n = 5.1`, not a rounded
  rectangle. Measured against a real system icon's silhouette it tracks Apple's
  curve to within one percent.
- **824 points of tile inside a 1024 canvas**, centred. That is Apple's own
  proportion — a system icon measures 818, and the rest is the shadow's room.
- **The mark is centred on its centre of mass, not its bounding box.** A bookmark
  loses mass at the notch, so box-centring leaves it visibly sitting high.
- The tile is `#1A1918`, a hair above the app's `#100F0F`, so the icon still has
  an edge against a dark desktop. The mark is the accent, `#3AA99F`.
- One soft contact shadow, the macOS standard. No bevel, no glow.

Run it, then `iconutil -c icns Vault.iconset -o Vault.icns` over the ten
sizes from 16 up to 512@2x.

## The test that decides it

Render the candidate at 256, 128, 64, 32 and **16** on a dark strip and look at
the 16. Three of the four symbols generated for this round were fine at 1024 and
died small: concentric arcs turned into a Wi-Fi badge, stacked bars into a
hamburger menu, and a four-blade aperture into a featureless donut. The bookmark
was the only one still readable as itself at 16 pixels, which is the only size
the Dock ever actually asks about.
