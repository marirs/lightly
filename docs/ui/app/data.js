/* Lightly design prototype: devices, photos and the screen registry.
   Design only. Nothing here processes photographs; every effect shown is a simulation. */

/* Representative devices with verified logical viewport sizes.
   iOS: CoreSimulator device profiles (mainScreenWidth/Height ÷ scale).
   Android: AVD config (hw.lcd width/height ÷ density/160), Pixel 9 Pro Fold display regions from its AVD. */
const DEVICES = [
  { id:'iphone17',       cls:'Standard phone', os:'ios',     name:'iPhone 17',              size:[402, 874],  orient:['portrait'],
    source:'CoreSimulator profile: 1206×2622 px @3x', safe:{ top:62, bottom:34, side:0 } },
  { id:'pixel9pro',      cls:'Standard phone', os:'android', name:'Pixel 9 Pro',            size:[427, 952],  orient:['portrait'],
    source:'AVD Pixel_9_Pro: 1280×2856 px, 480 dpi', safe:{ top:48, bottom:24, side:0 } },
  { id:'iphone17promax', cls:'Large phone',    os:'ios',     name:'iPhone 17 Pro Max',      size:[440, 956],  orient:['portrait'],
    source:'CoreSimulator profile: 1320×2868 px @3x', safe:{ top:62, bottom:34, side:0 } },
  { id:'pixel10proxl',   cls:'Large phone',    os:'android', name:'Pixel 10 Pro XL',        size:[448, 997],  orient:['portrait'],
    source:'AVD Pixel_10_Pro_XL: 1344×2992 px, 480 dpi', safe:{ top:48, bottom:24, side:0 } },
  { id:'fold-outer',     cls:'Foldable folded',   os:'android', name:'Pixel 9 Pro Fold · outer', size:[443, 994], orient:['portrait'],
    source:'AVD Pixel 9 Pro Fold display region 0.1: 1080×2424 px, 390 dpi', safe:{ top:48, bottom:24, side:0 } },
  { id:'fold-inner',     cls:'Foldable unfolded', os:'android', name:'Pixel 9 Pro Fold · inner', size:[852, 883], orient:['portrait', 'landscape'],
    source:'AVD Pixel 9 Pro Fold: 2076×2152 px, 390 dpi; hinge on the centre line', safe:{ top:40, bottom:24, side:0 }, hinge:true },
  { id:'ipadpro11',      cls:'11-inch tablet', os:'ios',     name:'iPad Pro 11"',           size:[834, 1210], orient:['portrait', 'landscape'],
    source:'CoreSimulator profile: 1668×2420 px @2x', safe:{ top:24, bottom:20, side:0 } },
  { id:'pixeltablet',    cls:'11-inch tablet', os:'android', name:'Pixel Tablet',           size:[800, 1280], orient:['portrait', 'landscape'],
    source:'AVD Pixel Tablet: 2560×1600 px, 320 dpi', safe:{ top:32, bottom:24, side:0 } },
  { id:'ipadpro13',      cls:'13-inch tablet', os:'ios',     name:'iPad Pro 13"',           size:[1032, 1376], orient:['portrait', 'landscape'],
    source:'CoreSimulator profile: 2064×2752 px @2x', safe:{ top:24, bottom:20, side:0 } },
];

/** Logical size and layout mode for a device in an orientation.
    below: controls under the photo (phones, folded) · wide: centred controls under a large photo (tablet portrait)
    side: panel and tool rail beside the photo (tablet landscape) · splitV / splitH: panes either side of the fold. */
function layoutFor(device, orientation) {
  const [w0, h0] = device.size, land = orientation === 'landscape';
  const w = land ? Math.max(w0, h0) : Math.min(w0, h0), h = land ? Math.min(w0, h0) : Math.max(w0, h0);
  let mode = 'below';
  if (device.id === 'fold-inner') mode = land ? 'splitH' : 'splitV';
  else if (/tablet|ipad/.test(device.id)) mode = land ? 'side' : 'wide';
  const big = device.cls === '13-inch tablet';
  return { w, h, mode, land, big, panel: big ? 400 : 360, content: big ? 640 : 600 };
}

/* Real photographs (licensed sample set, experiments/lut3d/photos). Faces are fractions of the image.
   `subject` approximates the person as head + body ellipses: the illustration of subject separation. */
const P = (n) => `/docs/ui/assets/photos/${n}.jpg`;
const PHOTOS = {
  lake:     { src:P('landscape_02'), thumb:P('landscape_02_thumb'), ratio:1067/1600, name:'Mountain lake', faces:[] },
  field:    { src:P('landscape_03'), thumb:P('landscape_03_thumb'), ratio:1600/1067, name:'Field and sky', faces:[] },
  sunset:   { src:P('sunset_02'),    thumb:P('sunset_02_thumb'),    ratio:1600/1067, name:'Sunset meadow', faces:[] },
  man:      { src:P('portrait_deep_03'), thumb:P('portrait_deep_03_thumb'), ratio:1067/1600, name:'Portrait, studio',
              faces:[{ x:.37, y:.09, w:.28, h:.30 }], subject:[{ cx:.51, cy:.22, rx:.16, ry:.18 }, { cx:.5, cy:.74, rx:.52, ry:.44 }] },
  smile:    { src:P('portrait_deep_02'), thumb:P('portrait_deep_02_thumb'), ratio:1600/1067, name:'Portrait, outdoors',
              faces:[{ x:.34, y:.10, w:.27, h:.50 }], subject:[{ cx:.47, cy:.33, rx:.18, ry:.34 }, { cx:.5, cy:.9, rx:.48, ry:.42 }] },
  woman:    { src:P('portrait_medium_02'), thumb:P('portrait_medium_02_thumb'), ratio:1065/1600, name:'Portrait by a wall',
              faces:[{ x:.29, y:.37, w:.22, h:.25 }], subject:[{ cx:.43, cy:.45, rx:.24, ry:.2 }, { cx:.53, cy:.86, rx:.44, ry:.36 }], target:{ x:.40, y:.48 } },
  blonde:   { src:P('portrait_light_01'), thumb:P('portrait_light_01_thumb'), ratio:1067/1600, name:'Portrait, window light',
              faces:[{ x:.26, y:.26, w:.29, h:.40 }], subject:[{ cx:.41, cy:.45, rx:.22, ry:.27 }, { cx:.46, cy:.92, rx:.44, ry:.32 }] },
  bar:      { src:P('night_03'),  thumb:P('night_03_thumb'),  ratio:1067/1600, name:'Bar at night', faces:[], people:true },
  street:   { src:P('wellexposed_03'), thumb:P('wellexposed_03_thumb'), ratio:1200/1600, name:'Street', faces:[] },
};
const PICKER_ORDER = ['woman', 'lake', 'man', 'field', 'smile', 'sunset', 'blonde', 'bar', 'street'];
const BACKGROUNDS = [P('landscape_01'), P('sunset_03'), P('wellexposed_02'), P('backlit_02')];
const SWATCHES = ['#F4F1EC', '#D9D4CC', '#9AA3A8', '#3C4A55', '#1F2328', '#C9A27E', '#8A5A44', '#4E6B5A'];
const GRADIENTS = ['linear-gradient(160deg,#F6D5B8,#9EB7D6)', 'linear-gradient(180deg,#20242C,#5B6476)', 'linear-gradient(140deg,#E9E4DA,#BFC8C2)', 'linear-gradient(170deg,#F0B7A4,#6E5A86)'];

/* Screen registry. Every entry renders in every applicable layout; `photo` and `state` seed the session. */
const J = {
  start:'Start and photo choice', open:'Opening and automatic Develop', develop:'Develop', background:'Background',
  portrait:'Portrait', edit:'Edit', effects:'Effects', watermark:'Watermark', border:'Border',
  save:'Compare, save and leaving', more:'More, preferences, legal and about', recovery:'Recovery states', demo:'Combined edit, one session',
};
