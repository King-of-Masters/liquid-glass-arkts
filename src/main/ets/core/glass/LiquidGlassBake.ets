/**
 * 液态玻璃烘焙器 —— 把 sdegenaar/liquid_glass_widgets 的着色器逐行移植成 ArkTS（CPU）。
 *
 * 对照源码（MIT，Copyright 2025 Tim Lehmann / 2026 Sebastian Degenaar）：
 *   - shaders/render.glsl                       → getHighlightColor / applySaturation / applyGlassColor
 *   - shaders/sdf.glsl                          → sdfEllipse / fastPow / squircleShape / sdfSquircle（圆与超椭圆面板）
 *   - shaders/liquid_glass_geometry_blended.frag → circleGeometry() / panelGeometry()（SDF→法线/高度/alpha）
 *   - shaders/liquid_glass_render.frag          → renderGlassPixel()（折射 + 色散 + 染色 + 白化 + 边缘光 + 弯月面 + 菲涅尔）
 *   - 参数默认值 = lib/src/engine/liquid_glass_settings.dart 构造默认 + lib/constants/glass_defaults.dart
 *
 * 为什么是 CPU 烘焙：ArkUI 声明式层没有自定义 fragment shader，也拿不到 backdrop；
 * 而按钮与卡片都浮在**纯平**的页面背景上（深浅色各一），backdrop 均匀 → 折射采到的就是它自己。
 * 所以一次性把着色器输出烘成 PixelMap 挂在 Image 上，与逐帧着色器的输出逐像素一致。
 * 要压在有内容的地方时，把 bake() 里的 backdropSampler 换成 componentSnapshot 的采样器即可，
 * 下面的着色器逻辑不用动一行。
 *
 * 未移植（默认关闭、且与本场景无关的独立子系统，移植了也只是死代码）：
 *   uPinchStrength 凹透镜横捏（iOS 26 胶囊指示器）、uFrost 霜化（需 backdrop 的两趟模糊）、
 *   触摸镜面（uTouchIntensity）、平台视图穿透（uPlatformViewMode）。接口留着，需要时再补。
 */

import { image } from '@kit.ImageKit';

// ── 常量（render.glsl） ────────────────────────────────────────────────

/** ITU-R Rec.709 亮度权重（shader 的 LUMA_WEIGHTS；之前是 BT.601，作者已更正） */
const LUMA_R: number = 0.2126;
const LUMA_G: number = 0.7152;
const LUMA_B: number = 0.0722;

// ── 数学助手（GLSL 内建函数的逐行对应） ─────────────────────────────────

function clamp(x: number, lo: number, hi: number): number {
  return Math.min(Math.max(x, lo), hi);
}
function mix(a: number, b: number, t: number): number {
  return a + (b - a) * t;
}
function mix3(a: number[], b: number[], t: number): number[] {
  return [mix(a[0], b[0], t), mix(a[1], b[1], t), mix(a[2], b[2], t)];
}
function smoothstep(e0: number, e1: number, x: number): number {
  const t = clamp((x - e0) / (e1 - e0), 0, 1);
  return t * t * (3 - 2 * t);
}
function dot2(ax: number, ay: number, bx: number, by: number): number {
  return ax * bx + ay * by;
}
function len2(x: number, y: number): number {
  return Math.sqrt(x * x + y * y);
}

// ── render.glsl 的共享函数 ──────────────────────────────────────────────

/** render.glsl: getHighlightColor(backgroundColor, targetBrightness) —— 亮度自适应的高光色 */
function getHighlightColor(bgR: number, bgG: number, bgB: number, targetBrightness: number): number[] {
  const luminance = LUMA_R * bgR + LUMA_G * bgG + LUMA_B * bgB;
  const maxComponent = Math.max(bgR, bgG, bgB);
  const lum = luminance * 2.5;
  const lumFactor = lum / (1.0 + lum);
  const sat = maxComponent * 2.5;
  const satFactor = sat / (1.0 + sat);
  const colorInfluence = lumFactor * satFactor;
  const inv = 1.0 / Math.max(luminance, 0.001);
  const tinted = [bgR * inv * targetBrightness, bgG * inv * targetBrightness, bgB * inv * targetBrightness];
  return mix3([targetBrightness, targetBrightness, targetBrightness], tinted, colorInfluence);
}

/** render.glsl: applySaturation(color, saturation) —— Rec.709 保亮度饱和 */
function applySaturation(color: number[], saturation: number): number[] {
  const luminance = LUMA_R * color[0] + LUMA_G * color[1] + LUMA_B * color[2];
  return [
    clamp(mix(luminance, color[0], saturation), 0, 1),
    clamp(mix(luminance, color[1], saturation), 0, 1),
    clamp(mix(luminance, color[2], saturation), 0, 1)
  ];
}

/** render.glsl: applyGlassColor(liquidColor, glassColor, bodyMode=0) —— iOS 26 亮度守恒染色 */
function applyGlassColor(liquid: number[], glass: number[], glassA: number): number[] {
  // bodyMode 我们只跑 0（adaptive）。glassColor.a == 0 时着色器 mix 天然返回 liquidColor
  const direct = [mix(liquid[0], glass[0], glassA), mix(liquid[1], glass[1], glassA), mix(liquid[2], glass[2], glassA)];
  const backdropLum = LUMA_R * liquid[0] + LUMA_G * liquid[1] + LUMA_B * liquid[2];
  const glassLum = LUMA_R * glass[0] + LUMA_G * glass[1] + LUMA_B * glass[2];
  const tinted = [
    clamp(glass[0] + (backdropLum - glassLum), 0, 1),
    clamp(glass[1] + (backdropLum - glassLum), 0, 1),
    clamp(glass[2] + (backdropLum - glassLum), 0, 1)
  ];
  const chroma = Math.max(glass[0], glass[1], glass[2]) - Math.min(glass[0], glass[1], glass[2]);
  const chromaWeight = clamp(chroma * 8.0, 0, 1);
  const lumMix = mix3(liquid, tinted, glassA);
  return mix3(direct, lumMix, chromaWeight);
}

// ── sdf.glsl ────────────────────────────────────────────────────────────

/** sdf.glsl: sdfEllipse(p, r) */
function sdfEllipse(px: number, py: number, rx: number, ry: number): number {
  const rrx = Math.max(rx, 1e-4);
  const rry = Math.max(ry, 1e-4);
  const invRx = 1.0 / rrx, invRy = 1.0 / rry;
  const k1 = Math.hypot(px * invRx, py * invRy);
  const k2 = Math.hypot(px * invRx * invRx, py * invRy * invRy);
  return (k1 * (k1 - 1.0)) / Math.max(k2, 1e-4);
}

// ── sdf.glsl 的解析超椭圆 SDF（Ln-norm squircle，99-135 行） ────────────
// 纯 Lamé 曲线（|x|^n + |y|^n = 1），不是分段拼的圆角矩形 —— 45° 拼缝处的
// 混色瑕疵被彻底消掉，与 Flutter 原生 RoundedSuperellipseBorder（ClipRSuperellipse）一致。

/** sdf.glsl:99-101 fastPow(x, n) —— exp2(n * log2(max(x, 1e-4)))，GLSL 内建 pow 的逐行对应 */
export function fastPow(x: number, n: number): number {
  return Math.pow(2, n * Math.log2(Math.max(x, 1e-4)));
}

/** sdf.glsl:103-113 squircleShape(p, b, zone, n) —— 以 Lamé 指数 n 为角的圆角超椭圆形状函数。
 *
 * 直边 / 内区快路径（与原式**严格等价**，只是省掉 transcendental）：
 *   m 的某一分量为 0 时，Lamé 角 (0^n + 1^n)^(1/n) ≡ 1，于是 corner ≡ M —— 直边上的 SDF
 *   就是到该边的欧氏距离。面板这类长条形状绝大多数采样点落在直边，而原式在这里照样
 *   跑三次 fastPow（6 次 pow/log2），实测这是整条烘焙链的绝对大头（3 秒级）。
 *   舍入差 ≤ 1e-13（fastPow(0,n) 被钳到 1e-4^n，n≈3.26 时约 1e-13）。
 */
export function squircleShape(px: number, py: number, bx: number, by: number,
  zone: number, n: number): number {
  const qx = Math.abs(px) - bx + zone;
  const qy = Math.abs(py) - by + zone;
  const mx = Math.max(qx, 0.0), my = Math.max(qy, 0.0);
  const M = Math.max(mx, my);
  const inner = Math.min(Math.max(qx, qy), 0.0);
  if (M <= 1e-4) {
    return inner - zone;
  }
  if (mx === 0.0 || my === 0.0) {
    return inner + M - zone;
  }
  const mNormX = mx / M, mNormY = my / M;
  return inner + M * fastPow(fastPow(mNormX, n) + fastPow(mNormY, n), 1.0 / n) - zone;
}

/**
 * sdfSquircle 的形状参数 + 求值：zone / n 只由 (bx, by, r) 决定，整块面板是常量，
 * 逐像素调用前先建一次 —— 省掉每次调用的一次 log2（烘焙是 30~65 万次调用，
 * 这一项单独就占大头）。`at()` 与 `sdfSquircle()` 逐位等价。
 */
export class SquircleShape {
  bx: number = 0;
  by: number = 0;
  zone: number = 0;
  n: number = 0;

  constructor(bx: number, by: number, r: number) {
    this.bx = bx;
    this.by = by;
    const boxShort = Math.min(bx, by);
    const rr = Math.min(r, boxShort);
    this.zone = Math.min(rr * 1.528, boxShort);
    const base = 1.0 - 0.29289322 * (rr / Math.max(this.zone, 1e-4));
    this.n = -1.0 / Math.log2(clamp(base, 0.5, 0.9999));
  }

  at(px: number, py: number): number {
    return squircleShape(px, py, this.bx, this.by, this.zone, this.n);
  }
}

/**
 * sdf.glsl:128-135 sdfSquircle(p, b, r) —— 带优雅退化的解析超椭圆 SDF。
 *
 * 关键（源码注释里的 CRITICAL）：Lamé 指数 n 由**钳过之后的 zone** 决定，
 * 不是原始的 r*1.528 —— 这样 SDF 的光照和梯度才与 Flutter 的
 * RoundedSuperellipseBorder 裁剪严丝合缝：
 *   boxShort = min(bx, by)；r = min(r, boxShort)
 *   zone = min(r * 1.528, boxShort)
 *   base = 1 - 0.29289322 * (r / zone)          （0.29289322 = 1 - 1/√2）
 *   n    = -1 / log2(clamp(base, 0.5, 0.9999))
 * 三档退化：
 *   普通超椭圆  zone = r*1.528 未被钳  → base 恒定 → n ≈ 3.26
 *   部分钳制    zone < r*1.528         → n 平滑下降
 *   整片胶囊    r ≥ boxShort → zone = r → base = 1/√2 → n = 2（纯圆角）
 * 若拿未钳的 zone 推 n，会画出 n≈3.26 的方形 SDF，配着已被 Flutter 钳成圆的
 * 裁剪，胶囊形上光照/辉光会相对可见边缘错位。
 *
 * r = bx = by 时形状就是圆盘，必须**严格**等于圆 SDF |p| - r：fastPow 的
 * log2/exp2 往返带 ~1e-8 的舍入差，等值断言过不去，故这条退化走精确 Math.hypot。
 */
export function sdfSquircle(px: number, py: number, bx: number, by: number, r: number): number {
  const boxShort = Math.min(bx, by);
  const rr = Math.min(r, boxShort);
  if (bx === by && r >= boxShort) {
    return Math.hypot(px, py) - rr;
  }
  const zone = Math.min(rr * 1.528, boxShort);
  const base = 1.0 - 0.29289322 * (rr / Math.max(zone, 1e-4));
  const n = -1.0 / Math.log2(clamp(base, 0.5, 0.9999));
  return squircleShape(px, py, bx, by, zone, n);
}

// ── 几何层（liquid_glass_geometry_blended.frag） ────────────────────────

class GeometryPixel {
  nx: number = 0;
  ny: number = 0;
  height: number = 0;   // 物理 px
  alpha: number = 0;
}

/**
 * circleGeometry / panelGeometry 共用的后半段：由 5 个 SDF 采样值
 * （中心 + 上下左右邻域）做中心差分梯度 → sdN → 法线/高度/alpha。
 * 对照 geometry_blended.frag 的梯度与 sdN 段，数值与原先 circleGeometry
 * 内联版逐位一致（圆按钮不许回归）。
 */
function geometryFromSamples(sd: number, sdPX: number, sdMX: number, sdPY: number, sdMY: number,
  stepDist: number, thicknessPx: number, dpr: number, out: GeometryPixel): void {
  const dx = (sdPX - sdMX) / (2.0 * stepDist);
  const dy = (sdPY - sdMY) / (2.0 * stepDist);
  const gradMag = Math.sqrt(dx * dx + dy * dy);
  const sdN = gradMag > 0.1 ? sd / gradMag : sd;

  const smoothing = 1.5 * Math.max(1.0, dpr);
  const alpha = smoothstep(smoothing * 0.5, -smoothing * 0.5, sdN);
  if (alpha < 0.01) {
    out.alpha = 0;
    return;
  }
  // 法线：n_cos / n_sin 是"斜率转单位法线"的 trick（见着色器注释）
  const nCos = Math.max(thicknessPx + sdN, 0.0) / thicknessPx;
  const nSin = Math.sqrt(Math.max(0.0, 1.0 - nCos * nCos));
  const nx0 = dx * nCos, ny0 = dy * nCos, nz0 = nSin;
  const nl = Math.sqrt(nx0 * nx0 + ny0 * ny0 + nz0 * nz0) || 1.0;
  out.nx = nx0 / nl;
  out.ny = ny0 / nl;
  out.alpha = alpha;
  if (sdN >= 0.0 || thicknessPx <= 0.0) {
    out.alpha = 0;
    return;
  }
  const x = thicknessPx + sdN;
  out.height = sdN < -thicknessPx ? thicknessPx : Math.sqrt(Math.max(0.0, thicknessPx * thicknessPx - x * x));
}

/**
 * 单圆的几何烘焙：diameterPx（物理 px 直径）+ thicknessPx（物理 px 厚度）。
 * 对照 geometry_blended.frag：sceneSDF → 中心差分梯度 → sdN → 法线/高度/alpha。
 */
function circleGeometry(fx: number, fy: number, cx: number, cy: number, rPx: number,
  thicknessPx: number, dpr: number, out: GeometryPixel): void {
  // sceneSDF = 单圆：sdfEllipse(p - center, r, r)
  const sd = sdfEllipse(fx - cx, fy - cy, rPx, rPx);

  const stepDist = dpr / 3.0;
  const sdPX = sdfEllipse(fx + stepDist - cx, fy - cy, rPx, rPx);
  const sdMX = sdfEllipse(fx - stepDist - cx, fy - cy, rPx, rPx);
  const sdPY = sdfEllipse(fx - cx, fy + stepDist - cy, rPx, rPx);
  const sdMY = sdfEllipse(fx - cx, fy - stepDist - cy, rPx, rPx);
  geometryFromSamples(sd, sdPX, sdMX, sdPY, sdMY, stepDist, thicknessPx, dpr, out);
}

/**
 * 面板（圆角超椭圆）的几何烘焙：(fx, fy) 以形状中心为原点。与 circleGeometry 同构，
 * SDF 换成 `SquircleShape`（形状参数由调用方建一次，逐像素复用）。
 */
function panelGeometry(fx: number, fy: number, shape: SquircleShape,
  thicknessPx: number, dpr: number, out: GeometryPixel): void {
  const sd = shape.at(fx, fy);

  const stepDist = dpr / 3.0;
  const sdPX = shape.at(fx + stepDist, fy);
  const sdMX = shape.at(fx - stepDist, fy);
  const sdPY = shape.at(fx, fy + stepDist);
  const sdMY = shape.at(fx, fy - stepDist);
  geometryFromSamples(sd, sdPX, sdMX, sdPY, sdMY, stepDist, thicknessPx, dpr, out);
}

// ── 渲染层（liquid_glass_render.frag main） ─────────────────────────────

export class GlassMaterial {
  /** 直径（逻辑 vp；渲染时乘 DPR） */
  diameterVp: number = 36;
  dpr: number = 2;

  // ── 光学（uOpticalProps / uLightConfig / uLightDirection）── LiquidGlassSettings 默认
  thickness: number = 20;          // uOpticalProps.z（逻辑 px，×dpr/3）
  refractiveIndex: number = 1.2;   // uOpticalProps.x
  chromaticAberration: number = 0.01; // uOpticalProps.y（折射带的色散比例）
  lightIntensity: number = 0.5;    // uLightConfig.x
  ambientStrength: number = 0.0;   // uLightConfig.y
  saturation: number = 1.5;        // uLightConfig.z
  lightAngle: number = 0.75 * Math.PI; // GlassDefaults.lightAngle（光从左上来）
  // ── 边缘（uEdgeConfig）──
  ambientRim: number = 0.0;        // uEdgeConfig.x（额外的环带宽度；默认关）
  fresnelStrength: number = 1.0;   // uEdgeConfig.y
  edgeAbsorption: number = 0.0;    // uEdgeConfig.w（弯月面暗化；默认关）
  /** 透镜模型：0 = 球面（严格 Snell 折射，默认）；1 = 视差（paraxial） */
  lensModel: number = 0;
  // ── 染色（uGlassColor）──
  glassColor: number[] = [1, 1, 1]; // RGB
  glassColorA: number = 0.0;       // alpha（默认透明 = 不染色）
  // ── 白化（uWhiten）──
  whitenStrength: number = 0.0;
  whitenGated: boolean = true;
  // ── iOS 27 描边/边缘光（uRimConfig）──
  rimShade: number = 0.0;          // uRimConfig.x（发丝暗线强度）
  rimShadeEnds: number = 0.2;      // uRimConfig.z
  rimLight: number = 0.0;          // uRimConfig.y（发丝内侧的亮点）
}

/**
 * iOS 27 `glassEffect(.regular)` 材质（LiquidGlassSettings.ios27Light / ios27Dark）：
 * 这就是我们这两颗按钮要的样子 —— 平浅背景上能看见的是**染色 + 弯月面 + 发丝暗线 + 边缘光**，
 * 折射本身是均匀的（背景均匀）。frost 那条路（两趟模糊）对均匀背景是恒等操作，略过。
 */
export function ios27Material(diameterVp: number, dpr: number, isDark: boolean): GlassMaterial {
  const m = new GlassMaterial();
  m.diameterVp = diameterVp;
  m.dpr = dpr;
  m.glassColor = [1, 1, 1];
  m.glassColorA = isDark ? 0.12 : 0.53;      // 0x1FFFFFFF / 0x87F8F8F8（Light 是近白 #F8F8F8）
  m.saturation = isDark ? 1.4 : 2.1;
  m.thickness = 32;
  m.refractiveIndex = 1.24;
  m.lensModel = 1;                           // paraxial
  m.lightAngle = isDark ? -Math.PI / 2 : Math.PI / 2;   // 深：光从下方来；浅：光从上方来
  m.lightIntensity = 0;
  m.fresnelStrength = 0;
  m.chromaticAberration = 0;
  m.edgeAbsorption = 0.035;
  m.rimShade = isDark ? 0.45 : 1.0;
  m.rimShadeEnds = isDark ? 0 : 0.2;
  m.rimLight = isDark ? 1.15 : 1.0;
  return m;
}

/** 背景采样器：uvw 是整幅图的标准化坐标（uniform 的话这个返回常量即可） */
export type BackdropSampler = (u: number, v: number) => number[];

/** 均匀背景：按钮浮在纯平页面上时用它 —— 折射采到的就是它自己，效果逐像素等同真着色器 */
export function uniformBackdrop(r: number, g: number, b: number): BackdropSampler {
  return (_u: number, _v: number): number[] => [r, g, b];
}

/** GLSL 的 refract()：I 入射方向、N 法线、eta = n1/n2 */
function refractGLSL(ix: number, iy: number, iz: number, nx: number, ny: number, nz: number, eta: number): number[] {
  const d = nx * ix + ny * iy + nz * iz;
  const k = 1.0 - eta * eta * (1.0 - d * d);
  if (k < 0) {
    return [0, 0, 0];
  }
  const f = eta * d + Math.sqrt(k);
  return [eta * ix - f * nx, eta * iy - f * ny, eta * iz - f * nz];
}

/** 一次烘焙里不变的量（材质派生量 + 背景采样器），圆与面板共用一份 */
class GlassRenderCtx {
  m: GlassMaterial;
  /** 画布宽/高（物理 px）：uv 归一化与 maxReach 用 */
  physW: number;
  physH: number;
  thicknessPx: number;
  dprScale: number;
  lightX: number;
  lightY: number;
  baseHeight: number;
  maxReach: number;
  backdrop: BackdropSampler;

  constructor(m: GlassMaterial, physW: number, physH: number, backdrop: BackdropSampler) {
    this.m = m;
    this.physW = physW;
    this.physH = physH;
    this.thicknessPx = m.thickness * (m.dpr / 3.0);   // render object: effectiveThickness * (dpr/3)
    this.dprScale = m.dpr / 3.0;                      // uEdgeConfig.z
    this.lightX = Math.cos(m.lightAngle);
    this.lightY = -Math.sin(m.lightAngle);            // _cachedLightDir
    this.baseHeight = this.thicknessPx * 8.0;
    this.maxReach = 0.5 * Math.min(physW, physH);     // shader: 0.5 * min(uGeometrySize.x, uGeometrySize.y)
    this.backdrop = backdrop;
  }
}

/**
 * 渲染主链（liquid_glass_render.frag main）：吃一个 GeometryPixel + 像素坐标，
 * 把 RGBA（UNPREMUL）写进 bytes[o..o+3]。圆按钮与面板边缘覆盖层只走这一条链 ——
 * 折射/色散/染色/白化/边缘光/弯月面/菲涅尔/iOS27 发丝暗线+边缘光全在这里，
 * 不许再长出会漂移的第二份实现。
 * overlay = true 只保留鼓边带：alpha = geo.alpha × (1 - smoothstep(0.55, 1, 归一化高度))，
 * 平顶深内部权重为 0 —— 与面板快路径写的 0 同值，交界处无缝。
 */
function renderGlassPixel(ctx: GlassRenderCtx, geo: GeometryPixel, x: number, y: number,
  overlay: boolean, bytes: Uint8Array, o: number): void {
  const m = ctx.m;
  const thicknessPx = ctx.thicknessPx;
  const dprScale = ctx.dprScale;
  const lightX = ctx.lightX, lightY = ctx.lightY;
  const baseHeight = ctx.baseHeight;
  const maxReach = ctx.maxReach;
  const backdrop = ctx.backdrop;
  const physW = ctx.physW, physH = ctx.physH;

  // 最终 alpha（覆盖层只盖鼓边带）；提前算好，开头短路与末尾写入共用同一个值
  const normalizedHeight = thicknessPx > 0 ? geo.height / thicknessPx : 0;
  const a = overlay
    ? geo.alpha * (1.0 - smoothstep(0.55, 1.0, normalizedHeight))
    : geo.alpha;
  if (a < 0.01) {
    bytes[o + 3] = 0;
    return;
  }

  // ── decode normal（V1 编码的逆操作已经在 circleGeometry 里直接产出单位法线） ──
  const normalXYx = geo.nx, normalXYy = geo.ny;
  const normalZSq = Math.max(0.0, 1.0 - dot2(normalXYx, normalXYy, normalXYx, normalXYy));
  const normalZ = Math.sqrt(normalZSq);
  const height = geo.height;

  // ── 折射 ──
  const refractScale = 1.0; // uOpticalProps.w（render object 里就是 1.0）
  let dispX: number, dispY: number;
  if (m.lensModel === 1) {
    // 视差透镜（paraxial，iOS 27 预设用它）：deviation = (n-1) × slope，
    // slope 取 sin(入射角)²；normalXY 是 sin(入射角) 沿 bevel 线性衰减 →
    // 位移沿 bevel 二次方抬升，过折返点折叠（镜像压缩的内景带，见 shader 注释）
    const nxyLen = len2(normalXYx, normalXYy);
    dispX = -normalXYx * nxyLen * baseHeight * (m.refractiveIndex - 1.0);
    dispY = -normalXYy * nxyLen * baseHeight * (m.refractiveIndex - 1.0);
  } else {
    // 球面透镜（默认档）：严格 Snell 折射
    const invN = 1.0 / Math.max(m.refractiveIndex, 0.001);
    const br = refractGLSL(0, 0, -1, normalXYx, normalXYy, normalZ, invN);
    const refractLen = (height + baseHeight) / Math.max(0.001, Math.abs(br[2]));
    dispX = br[0] * refractLen;
    dispY = br[1] * refractLen;
  }
  dispX *= refractScale;
  dispY *= refractScale;
  const reach = Math.hypot(dispX, dispY);
  if (reach > maxReach) {
    const f = maxReach / reach;
    dispX *= f;
    dispY *= f;
  }

  // ── rimDist / edgeFactor / thicknessScale（弯月面与边缘光的公共量） ──
  const cosTerm = Math.sqrt(Math.max(0.0, 1.0 - normalizedHeight * normalizedHeight));
  const rimDist = thicknessPx * (1.0 - cosTerm);

  // ── 背景采样（均匀背景的话折射位移采到的还是它自己） ──
  // 色散：R 用 ×(1+dispersion*0.5)、B 用 ×(1-dispersion*0.5) 的两个采样 ——
  // 均匀背景上三次都返回同一颜色，所以这块只在 backdropSampler 换成快照时才真正起作用。
  const uvx = (x + 0.5 + dispX) / physW, uvy = (y + 0.5 + dispY) / physH;
  const dispersionStrength = m.chromaticAberration * 0.5;
  const bgMid = backdrop(uvx, uvy);
  const bgR = backdrop((x + 0.5 + dispX * (1.0 + dispersionStrength)) / physW,
    (y + 0.5 + dispY * (1.0 + dispersionStrength)) / physH);
  const bgB = backdrop((x + 0.5 + dispX * (1.0 - dispersionStrength)) / physW,
    (y + 0.5 + dispY * (1.0 - dispersionStrength)) / physH);
  // 组装折射色（对应 shader 的 R/G/B 三路采样）
  const refractColor = [bgR[0], bgMid[1], bgB[2]];

  // ── 染色（iOS 26 luminosity 守恒） ──
  let finalColor = applyGlassColor(refractColor, m.glassColor, m.glassColorA);

  // ── VQ4：内容自适应强度（黑底 1.2 浓，白底 0.8 淡） ──
  const backdropLuma = LUMA_R * refractColor[0] + LUMA_G * refractColor[1] + LUMA_B * refractColor[2];
  const adaptiveStrength = mix(1.2, 0.8, backdropLuma);
  finalColor = applySaturation(finalColor, m.saturation * adaptiveStrength);
  // 染色权重随强度微调（±20% 的 12%）
  finalColor = mix3(finalColor, m.glassColor,
    m.glassColorA * 0.12 * (adaptiveStrength - 1.0));

  // ── 白化面纱（默认 whitenStrength = 0 → 无操作） ──
  const whitenLuma = LUMA_R * finalColor[0] + LUMA_G * finalColor[1] + LUMA_B * finalColor[2];
  const whitenGate = m.whitenGated ? smoothstep(0.40, 0.80, whitenLuma) : 1.0;
  finalColor = mix3(finalColor, [1, 1, 1], clamp(m.whitenStrength, 0, 1) * whitenGate);

  // ── 边缘光照（directional specular + ambient，沿边缘带） ──
  const baseScale = 40.0 * Math.max(0.1, dprScale);
  const thicknessScale = clamp(baseScale / Math.max(thicknessPx, 1.0), 1.0, 4.0);
  const edgeThreshold = mix(0.8, 0.5, 1.0 / thicknessScale);
  const edgeFactor = thicknessPx < 0.01 ? 0.0 : 1.0 - smoothstep(0.0, edgeThreshold, normalizedHeight);

  // ── VQ5 弯月面暗化（edgeAbsorption 默认 0 → 无操作） ──
  const rRim = clamp(1.0 - normalizedHeight, 0, 1);
  const lensThickness = m.thickness < 0.01 ? 0.0 : Math.sqrt(Math.max(0.0, 1.0 - rRim * rRim));
  const rimThickness = 1.0 - lensThickness;
  const len2D = Math.max(len2(normalXYx, normalXYy), 1e-4);
  const rimNx = normalXYx / len2D, rimNy = normalXYy / len2D;
  const litness = dot2(rimNx, rimNy, lightX, lightY);
  const dirScale = mix(1.4, 0.6, litness * 0.5 + 0.5);
  const absorption = 1.0 - Math.sqrt(rimThickness) * m.edgeAbsorption * dirScale;
  finalColor = [finalColor[0] * Math.max(0, absorption), finalColor[1] * Math.max(0, absorption),
    finalColor[2] * Math.max(0, absorption)];

  if (edgeFactor > 0.01) {
    const anisoNx = normalXYx / len2D, anisoNy = normalXYy / len2D;
    const mainLight = Math.max(0.0, dot2(anisoNx, anisoNy, lightX, lightY));
    const oppositeLight = Math.max(0.0, dot2(anisoNx, anisoNy, -lightX, -lightY));
    const totalInfluence = mainLight + oppositeLight * 0.8;
    const directional = totalInfluence * Math.sqrt(totalInfluence) * m.lightIntensity * 3.0;
    const ambient = m.ambientStrength * 0.5;
    const brightnessRaw = (directional + ambient) * edgeFactor * thicknessScale * 0.8;
    const brightness = brightnessRaw / (1.0 + brightnessRaw);
    const hl = getHighlightColor(refractColor[0], refractColor[1], refractColor[2], 1.0);
    finalColor = mix3(finalColor, hl, brightness);
  }

  // ── VQ2 菲涅尔边缘提亮（rimBase = (1 - normalZ) * edgeFactor） ──
  const rimBase = (1.0 - normalZ) * edgeFactor;
  const ringWindow = 0.75 * Math.max(0.1, dprScale);
  const ring = (1.0 - smoothstep(m.ambientRim - ringWindow, m.ambientRim + ringWindow, rimDist))
    * (m.ambientRim > 0.001 ? 1.0 : 0.0);
  const fresnel = rimBase * 0.12 * m.fresnelStrength + ring * 0.45;
  finalColor = [
    clamp(finalColor[0] + fresnel, 0, 1),
    clamp(finalColor[1] + fresnel, 0, 1),
    clamp(finalColor[2] + fresnel, 0, 1)
  ];

  // ── iOS 27 rim light（rimLight 默认 0 → 无操作） ──
  if (m.rimLight > 0.001 && rimDist < 30.0 * dprScale) {
    const along = dot2(rimNx, rimNy, lightX, lightY);
    const lit = Math.max(along, 0.0);
    const opp = Math.max(-along, 0.0);
    const lobe = lit * lit * lit + 0.85 * opp * opp * opp;
    const inset = Math.max(0.0, rimDist - 2.25 * dprScale) / dprScale;
    const core = Math.exp(-inset / 1.5);
    const tail = Math.exp(-inset / 8.0);
    const bodyLuma = clamp(LUMA_R * finalColor[0] + LUMA_G * finalColor[1] + LUMA_B * finalColor[2], 0, 1);
    const ease = Math.pow(1.0 - bodyLuma, 0.3);
    const rimLight = m.rimLight * lobe * ease * (0.175 * core + 0.035 * tail);
    finalColor = [
      clamp(finalColor[0] + rimLight, 0, 1),
      clamp(finalColor[1] + rimLight, 0, 1),
      clamp(finalColor[2] + rimLight, 0, 1)
    ];
  }

  // ── iOS 27 发丝暗线（rimShade 默认 0 → 无操作） ──
  if (m.rimShade > 0.001) {
    // 对照源码：hairline = (1 - smoothstep(...)) * (1 - step(...)) —— 先各自算完再**相乘**。
    // 一度写成 1 - smoothstep * factor（减法优先），发丝暗线在圆心也被点亮，整体压暗 0.314
    //（255 → 175，单测 glassBakeProducesThemeCorrectPixels 就是抓这个的）。
    const hairline = (1.0 - smoothstep(0.75 * dprScale, 2.0 * dprScale, rimDist))
      * (normalizedHeight >= 0.999 ? 0.0 : 1.0);
    const across2 = 1.0 - litness * litness;
    const across = Math.pow(Math.max(across2, 0.0), 1.75);
    const shade = m.rimShade * 0.314 * mix(m.rimShadeEnds, 1.0, across);
    finalColor = [
      Math.max(finalColor[0] - shade * hairline, 0),
      Math.max(finalColor[1] - shade * hairline, 0),
      Math.max(finalColor[2] - shade * hairline, 0)
    ];
  }

  // shader 末尾是 fragColor = vec4(rgb * alpha, alpha)（GPU 预乘混合）；
  // PixelMap 按 UNPREMUL 存：rgb 不乘 alpha，透明度走 alpha 通道，ArkUI 自己混合
  bytes[o] = Math.round(clamp(finalColor[0], 0, 1) * 255);
  bytes[o + 1] = Math.round(clamp(finalColor[1], 0, 1) * 255);
  bytes[o + 2] = Math.round(clamp(finalColor[2], 0, 1) * 255);
  bytes[o + 3] = Math.round(a * 255);
}

/**
 * 烘一颗圆形液态玻璃按钮 → RGBA_8888 的 PixelMap。
 * 逐像素跑一遍 render.frag main() 的完整链路（默认档参数）。
 */
export function bakeGlassCircle(m: GlassMaterial, backdrop: BackdropSampler): image.PixelMap {
  const phys = Math.round(m.diameterVp * m.dpr);
  const bytes = renderGlassBytes(m, backdrop);
  const opts: image.InitializationOptions = {
    alphaType: image.AlphaType.UNPREMUL,
    editable: true,
    pixelFormat: image.PixelMapFormat.RGBA_8888,
    size: { height: phys, width: phys }
  };
  return image.createPixelMapSync(bytes.buffer, opts);
}

/**
 * 烘一块面板形液态玻璃（或它的边缘覆盖层）→ RGBA_8888 的 PixelMap。
 * 尺寸 = round(尺寸vp × dpr)；只负责 renderPanelBytes + 包装成 PixelMap，
 * **不做全局缓存**（尺寸变化由调用方自己判断）。
 */
export function bakeGlassPanel(m: GlassMaterial, widthVp: number, heightVp: number,
  radiusVp: number, backdrop: BackdropSampler, overlay: boolean): image.PixelMap {
  const wPx = Math.round(widthVp * m.dpr);
  const hPx = Math.round(heightVp * m.dpr);
  const bytes = renderPanelBytes(m, widthVp, heightVp, radiusVp, backdrop, overlay);
  const opts: image.InitializationOptions = {
    alphaType: image.AlphaType.UNPREMUL,
    editable: true,
    pixelFormat: image.PixelMapFormat.RGBA_8888,
    size: { height: hPx, width: wPx }
  };
  return image.createPixelMapSync(bytes.buffer, opts);
}

/**
 * 渲染层本体：与 bakeGlassCircle 同一条链，但返回裸字节（便于单测直接断言像素值）。
 * bytes[i*4+0..3] = RGBA（非预乘；像素圆外 alpha=0）。
 */
export function renderGlassBytes(m: GlassMaterial, backdrop: BackdropSampler): Uint8Array {
  const phys = Math.round(m.diameterVp * m.dpr);
  const cx = phys / 2, cy = phys / 2, rPx = phys / 2;
  const ctx = new GlassRenderCtx(m, phys, phys, backdrop);
  const geo = new GeometryPixel();
  const bytes = new Uint8Array(phys * phys * 4);

  for (let y = 0; y < phys; y++) {
    for (let x = 0; x < phys; x++) {
      const o = (y * phys + x) * 4;
      circleGeometry(x + 0.5, y + 0.5, cx, cy, rPx, ctx.thicknessPx, m.dpr, geo);
      renderGlassPixel(ctx, geo, x, y, false, bytes, o);
    }
  }
  return bytes;
}

/**
 * 面板渲染层本体：居中对称的圆角超椭圆（sdfSquircle），半宽半高 = (wPx/2, hPx/2)，
 * wPx = round(widthVp*dpr)、hPx = round(heightVp*dpr)、圆角 rPx = radiusVp*dpr。
 * 返回 Uint8Array(wPx*hPx*4)（RGBA 非预乘、行优先），约定同 renderGlassBytes。
 * overlay = true → 边缘覆盖层（深内部 alpha=0）；false → 整块玻璃（内部 alpha=1）。
 *
 * 性能：900vp×120vp @dpr2 约 50 万像素，逐像素全算是秒级，所以深内部走快路径 ——
 * 平台区（高度饱和成 thicknessPx、法线 (0,0,1)、alpha=1、edgeFactor=0）的链路输出是
 * 常量：rimLight 的 rimDist < 30*dprScale 条件伸不进平台区（rimDist 饱和值 =
 * thicknessPx = 32*dprScale ≥ 30*dprScale），且平台法线竖直时 lobe=0；发丝暗线同样
 * 被 normalizedHeight ≥ 0.999 闸掉。于是只有边缘的逐像素带真算，深内部
 * overlay=true 直接留 0，overlay=false 填「代表像素跑一次完整链路」得到的常量色。
 * 快路径假定 backdrop 在面板内部为常量（调用方传 uniformBackdrop）；
 * 带内/跳算交界逐字节一致，不允许出现接缝。
 */
export function renderPanelBytes(m: GlassMaterial, widthVp: number, heightVp: number,
  radiusVp: number, backdrop: BackdropSampler, overlay: boolean): Uint8Array {
  const wPx = Math.round(widthVp * m.dpr);
  const hPx = Math.round(heightVp * m.dpr);
  const rPx = radiusVp * m.dpr;
  const ctx = new GlassRenderCtx(m, wPx, hPx, backdrop);
  const thicknessPx = ctx.thicknessPx;
  const stepDist = m.dpr / 3.0;
  const bx = wPx / 2, by = hPx / 2;
  const bytes = new Uint8Array(wPx * hPx * 4);
  const geo = new GeometryPixel();
  // 形状参数（zone / n）整块面板是常量，建一次复用 —— 逐像素重算是烘焙慢的主因之一
  const shape = new SquircleShape(bx, by, rPx);

  // 跳算内边界：几何里 sdN = sd/gradMag，输出进平台区的条件是
  // sdN ≤ -max(thicknessPx, smoothing/2)（高度饱和 + alpha 饱和为 1）。
  // 该 SDF 中心差分的 |gradMag| ≤ 1.0001（Ln 范数梯度长 ≤1，只有 squircleShape
  // 里 M=1e-4 截断带 ~1e-4 级跳变），sd 侧取 1.05 倍为绝对裕量 —— 保证跳算的
  // 每个像素都已处于平台区，其链路输出与代表像素逐字节相同。
  const smoothing = 1.5 * Math.max(1.0, m.dpr);
  const bandInner = 1.05 * Math.max(thicknessPx, smoothing * 0.5);
  // 平台区的**便宜矩形判定**：形状铺满画布、只有四角被圆角切掉，切深 ≤ rPx*(1-1/√2)
  // （圆角矩形的上界；超椭圆比它更"满"、切得更浅，这个界是保守的）。所以离画布四边
  // 都 > bandInner + 切深 的点必在平台区，连 SDF 都不用算 —— 长条面板上这块占了
  // 三分之二的像素。
  const skip = bandInner + rPx * (1.0 - Math.SQRT1_2) + 1.0;

  const plate = new GeometryPixel();
  const fill = new Uint8Array(4);
  // 代表像素固定取画布正中：那里必在平台区，深内部的常量色就用它（比"第一个命中点"稳）
  if (!overlay) {
    panelGeometry(0, 0, shape, thicknessPx, m.dpr, plate);
    renderGlassPixel(ctx, plate, (wPx / 2) | 0, (hPx / 2) | 0, false, fill, 0);
  }

  // 直边带快路径（与逐像素**严格等价**，只是省掉重复的渲染链）：
  //   左 / 右直边（|py| < by-zone）上 SDF = |px|-bx、梯度 = (±1,0)，整列几何相同 → 整列同色；
  //   上 / 下直边（|px| < bx-zone）上 SDF = |py|-by、梯度 = (0,±1)，整行几何相同 → 整行同色；
  //   角区（两者都不成立）照旧逐像素。
  // 实测渲染链（每像素十来次 pow/exp + 小数组分配）是烘焙慢的绝对大头，而面板上
  // 95% 的边缘像素落在直边 —— 每列 / 每行算一次、其余复制即可。
  // 前提：backdrop 在面板内是常量（uniformBackdrop）；否则 uv 不同，复制会显出条带。
  const colDone = new Uint8Array(wPx);
  const rowDone = new Uint8Array(hPx);
  const colRGBA = new Uint8Array(wPx * 4);
  const rowRGBA = new Uint8Array(hPx * 4);
  const midY = (hPx / 2) | 0;
  const midX = (wPx / 2) | 0;
  const zone = shape.zone;

  for (let y = 0; y < hPx; y++) {
    const yc = y + 0.5 - by;
    const ySafe = y + 0.5 > skip && y + 0.5 < hPx - skip;
    const yStraight = Math.abs(yc) < by - zone;
    for (let x = 0; x < wPx; x++) {
      const o = (y * wPx + x) * 4;
      const xc = x + 0.5 - bx;
      let sd = 0.0;
      let platform = false;
      if (ySafe && x + 0.5 > skip && x + 0.5 < wPx - skip) {
        platform = true;
      } else {
        sd = shape.at(xc, yc);
        platform = sd <= -bandInner;
      }
      if (platform) {
        // 深内部：overlay 只盖边缘（链路算出来也是 0，字节本来就留 0）；
        // 整块玻璃填代表像素的常量色
        if (!overlay) {
          bytes[o] = fill[0];
          bytes[o + 1] = fill[1];
          bytes[o + 2] = fill[2];
          bytes[o + 3] = fill[3];
        }
        continue;
      }
      // 左 / 右直边带：整列同色
      if (yStraight && Math.abs(xc) >= bx - zone) {
        if (colDone[x] === 0) {
          panelGeometry(xc, 0, shape, thicknessPx, m.dpr, geo);
          renderGlassPixel(ctx, geo, x, midY, overlay, colRGBA, x * 4);
          colDone[x] = 1;
        }
        const c = x * 4;
        bytes[o] = colRGBA[c];
        bytes[o + 1] = colRGBA[c + 1];
        bytes[o + 2] = colRGBA[c + 2];
        bytes[o + 3] = colRGBA[c + 3];
        continue;
      }
      // 上 / 下直边带：整行同色
      if (Math.abs(xc) < bx - zone && Math.abs(yc) >= by - zone) {
        if (rowDone[y] === 0) {
          panelGeometry(0, yc, shape, thicknessPx, m.dpr, geo);
          renderGlassPixel(ctx, geo, midX, y, overlay, rowRGBA, y * 4);
          rowDone[y] = 1;
        }
        const c = y * 4;
        bytes[o] = rowRGBA[c];
        bytes[o + 1] = rowRGBA[c + 1];
        bytes[o + 2] = rowRGBA[c + 2];
        bytes[o + 3] = rowRGBA[c + 3];
        continue;
      }
      // 角区 / 其余：逐像素（中心采样值 sd 已为判定算过，补 4 个邻域点进共用几何）
      const sdPX = shape.at(xc + stepDist, yc);
      const sdMX = shape.at(xc - stepDist, yc);
      const sdPY = shape.at(xc, yc + stepDist);
      const sdMY = shape.at(xc, yc - stepDist);
      geometryFromSamples(sd, sdPX, sdMX, sdPY, sdMY, stepDist, thicknessPx, m.dpr, geo);
      renderGlassPixel(ctx, geo, x, y, overlay, bytes, o);
    }
  }
  return bytes;
}
