# liquid-glass-arkts

HarmonyOS NEXT / ArkTS 上的「液态玻璃」（Liquid Glass）实现 —— 把 Flutter 的
[`liquid_glass_widgets`](https://github.com/sdegenaar/liquid_glass_widgets) 着色器**逐行移植到 CPU**，
烘焙成一张 `PixelMap` 挂在 `Image` 上。

> **一句话原理**：ArkUI 声明式层没有运行时自定义 shader 的入口，所以这里把整条着色器链
> （折射 / 色散 / 染色 / 亮度守恒 / 色相饱和 / 白化 / 边缘光 / 弯月面 / 菲涅尔 / iOS 27 发丝暗线 + 边缘光）
> **在 CPU 上逐像素烘焙成一张 `PixelMap`**，再交给 `Image` 显示。
> 因此 —— **不依赖任何运行时自定义着色器能力**，纯 ArkTS，只依赖 `@kit.ImageKit`。

> **English (short)**: A CPU-side port of the `liquid_glass_widgets` (Flutter) GLSL shaders to ArkTS.
> The whole shader chain is evaluated per pixel on the CPU and baked into a `PixelMap`, so it works on
> stock ArkUI, which offers no runtime custom-shader entry point. Zero dependencies except `@kit.ImageKit`.

---

## 来源与致谢（请先读这段）

- 本项目是 [`sdegenaar/liquid_glass_widgets`](https://github.com/sdegenaar/liquid_glass_widgets)（MIT）着色器的
  **ArkTS 移植**，逐行对照下列文件写成：
  - `shaders/liquid_glass_render.frag` → `renderGlassPixel()`（折射 / 色散 / 染色 / 白化 / 边缘光 / 弯月面 / 菲涅尔 / iOS 27 描边）
  - `shaders/liquid_glass_geometry_blended.frag` → `circleGeometry()` / `panelGeometry()`（SDF → 法线 / 高度 / alpha）
  - `shaders/sdf.glsl` → `sdfEllipse` / `fastPow` / `squircleShape` / `sdfSquircle`（圆与解析超椭圆）
  - `shaders/render.glsl` → `getHighlightColor` / `applySaturation` / `applyGlassColor`
  - 参数默认值对照 `lib/src/engine/liquid_glass_settings.dart` 与 `lib/constants/glass_defaults.dart`
- **原作者：Sebastian Degenaar**（[pixel-innovations.com](https://pixel-innovations.com)），
  以及其上游 **Tim Lehmann**（[whynotmake.it](https://whynotmake.it)）。
- **着色器算法与视觉设计的功劳全部归他们。** 本仓库只负责 ArkTS / ArkUI 这一侧的落地
  （CPU 烘焙、超椭圆 SDF 的解析快路径、两个即用组件），不声称任何光学模型上的原创。

---

## 原理

### 为什么走 CPU 烘焙

- ArkUI 的声明式层**没有**自定义 fragment shader 的入口：`Image` / `Canvas` / `EffectComponent`
  都吃不到逐像素的片元回调，也没有办法把 backdrop 作为纹理传进自定义着色器。
- 面板 / 按钮这类控件**浮在纯平的页面背景上**（浅色一份、深色一份），backdrop 在整块玻璃范围内是常量。
  于是折射采到的就是它自己 —— 一次烘焙的输出与逐帧着色器的输出**逐像素一致**，没有必要每帧重算。
- 所以：把着色器输出烘成一张 `PixelMap`，挂到 `Image` 上。形状外 alpha = 0，玻璃体自带透明度，
  叠在你的底色 / 背景模糊之上即可。

### 烘焙的是什么（着色器链路里移植进来的每一项）

| 环节 | 说明 | 对应源码 |
| --- | --- | --- |
| SDF 形状 | 圆 = `sdfEllipse`；面板 = 解析超椭圆（Lamé 曲线）`sdfSquircle`，三档退化保证与 Flutter 的 `RoundedSuperellipseBorder` 严丝合缝 | `sdf.glsl:99-135` |
| 几何 | 中心差分梯度 → `sdN` → 法线 / 高度 / alpha（0.01 以下直接丢弃，边缘带外全透明） | `liquid_glass_geometry_blended.frag` |
| 折射 | 球面透镜（严格 Snell `refract()`）与视差透镜（paraxial，`(n-1) × slope`，iOS 27 预设用它），位移再按 `maxReach = 0.5 × min(w,h)` 钳制 | `liquid_glass_render.frag` |
| 色散 | R / B 两路分别用 `×(1 ± 0.5 × dispersion)` 的采样位置，G 取中间（均匀 backdrop 下三路同色） | 同上 |
| 染色 | iOS 26 保留亮度的染色（`applyGlassColor`），含 chroma 权重在「直接 mix」与「亮度补偿 mix」之间切换 | `render.glsl` |
| 自适应 | 背景越黑染色越浓（1.2）、越白越淡（0.8），并回馈到染色权重 | `liquid_glass_render.frag` |
| 色相饱和 | Rec.709 保亮度饱和（`applySaturation`） | `render.glsl` |
| 白化 | 可选的白色纱帘 + 亮度门控（默认强度 0 = 无操作） | `liquid_glass_render.frag` |
| 边缘光 | 方向主光 + 反向光 + 环境项，亮度走 `x/(1+x)` 软饱和，颜色由 `getHighlightColor` 依背景自适应 | `render.glsl` / `liquid_glass_render.frag` |
| 弯月面 | 按边缘带归一化高度做方向敏感的暗化（`edgeAbsorption`） | `liquid_glass_render.frag` |
| 菲涅尔 | `rimBase = (1 - n.z) × edgeFactor` 的边缘提亮 + 可选的环带 | `liquid_glass_render.frag` |
| iOS 27 描边 | 发丝暗线（rimShade，含 `pow(1 - litness², 1.75)` 的方向衰减与两端渐隐）+ 发丝内侧边缘光（rimLight，core/tail 双指数） | `liquid_glass_render.frag` |

### `PixelMap` 的 UNPREMUL 约定

着色器最后一行是 `fragColor = vec4(rgb * alpha, alpha)`（GPU 预乘混合）。
本包创建的 `PixelMap` 用 **`AlphaType.UNPREMUL`**：**RGB 不预乘 alpha，透明度走独立的 alpha 通道**，
由 ArkUI 自己在合成时乘。所以：

- 形状外像素 = `(0, 0, 0, 0)`；
- 想自己读像素做断言（单测 / 调试）时，拿到的 `bytes[i*4..i*4+3]` 就是**未预乘**的 RGBA。

---

## 快速开始

本仓库**不是一个可独立编译的 hap 工程** —— 它是一个「拷进你自己工程就能用」的源码包。
按下面的对应关系把文件复制进你的 HarmonyOS 工程，然后就能跑。

### 文件放哪

| 本包路径 | 拷到你的工程（Stage 模型典型布局） |
| --- | --- |
| `src/main/ets/core/glass/LiquidGlassBake.ets` | `entry/src/main/ets/core/glass/LiquidGlassBake.ets`（路径随意，但要保证组件里的相对 import 对得上） |
| `src/main/ets/ui/components/GlassCircle.ets` | `entry/src/main/ets/ui/components/GlassCircle.ets` |
| `src/main/ets/ui/components/GlassPanel.ets` | `entry/src/main/ets/ui/components/GlassPanel.ets` |
| `src/ohosTest/ets/test/GlassBake.test.ets` | `entry/src/ohosTest/ets/test/GlassBake.test.ets`（或 `entry/src/test/`，见下） |

包内三个源文件的相对 import 是按上表的**目录深度**写死的：
组件用 `../../core/glass/LiquidGlassBake`，测试用 `../../../main/ets/core/glass/LiquidGlassBake`。
换个位置放就得跟着改这两行。

把文件放进 `entry/src/test/` 的话（很多工程用的是这个目录），测试里的 import 要改成
`../main/ets/core/glass/LiquidGlassBake`，并在测试入口注册：

```ts
// entry/src/test/List.test.ets
import glassBakeTest from './GlassBake.test';

export default function testsuite() {
  glassBakeTest();
}
```

### 直接用烘焙函数

```ts
import { image } from '@kit.ImageKit';
import {
  bakeGlassCircle,
  bakeGlassPanel,
  ios27Material,
  renderGlassBytes,
  renderPanelBytes,
  uniformBackdrop
} from './core/glass/LiquidGlassBake';

// 组件里 dpr 这么取：const dpr = this.getUIContext().vp2px(1);
const dpr = 2;

// 1) 圆钮：30vp 直径 → 60×60 的 RGBA_8888 PixelMap
const circle: image.PixelMap = bakeGlassCircle(
  ios27Material(30, dpr, /* isDark */ false),
  uniformBackdrop(1, 1, 1));                       // 底下是纯白

// 2) 面板：200vp × 80vp、圆角 20vp。overlay = true 只画边缘带（深内部透明）
const edgePm: image.PixelMap = bakeGlassPanel(
  ios27Material(30, dpr, false),                   // diameterVp 只被圆形烘焙用到，面板给占位值即可
  200, 80, 20,
  uniformBackdrop(0.118, 0.118, 0.133),            // 深色主题下底下是 #1e1e22
  /* overlay */ true);

// 3) 只要裸字节（单测 / 自己拼 PixelMap / 存盘比对）
const bytes: Uint8Array = renderGlassBytes(ios27Material(30, dpr, false), uniformBackdrop(1, 1, 1));
const panelBytes: Uint8Array = renderPanelBytes(ios27Material(30, dpr, false), 200, 80, 20,
  uniformBackdrop(1, 1, 1), /* overlay */ true);
// bytes[(y * w + x) * 4 + 0..3] = R, G, B, A（非预乘；形状外 alpha = 0）
```

### 圆钮组件（`GlassCircle`）

玻璃本体 + 一个由调用方提供的插槽。**组件自己不处理点击**，点击外壳由你套在外面
（免得插槽里的子节点把点击吃掉，需要按压回弹的按钮要自己保留 `Pressable`）。

```ts
import { GlassCircle } from '../ui/components/GlassCircle';   // 路径按你放的位置改

@Entry
@Component
struct Toolbar {
  @State isDark: boolean = false;
  @State draft: string = '';

  // 插槽内容：本包不带图标组件，图标随你（SymbolGlyph / Image / Text / 自绘 Canvas）
  @Builder sendIcon() {
    Text('➤')
      .fontSize(14)
      .fontColor(this.isDark ? '#f4f5f7' : '#0b0c0e')
  }

  build() {
    Row() {
      Stack() {
        GlassCircle({
          isDark: this.isDark,          // @Prop：父组件翻转主题会重绘，取另一份烘好的图
          diameter: 30,
          shadowRadius: 12,
          shadowColor: '#99000000',
          backdropLight: '#ffffff',     // 玻璃浮在什么底色上：必须和真实背景一致
          backdropDark: '#1e1e22'
        }) {
          this.sendIcon()               // 尾随闭包 = content 插槽
        }
      }
      .onClick(() => { this.draft = ''; })
    }
    .width('100%')
  }
}
```

### 面板组件（`GlassPanel`）

默认 `edgeOnly: true`：深内部透明，只画鼓边 / 发丝暗线 / 边缘光，**盖在你自己那层底色或背景模糊之上**，
不会把卡片糊成一块实色。要整块玻璃就传 `edgeOnly: false`。
`Image` 挂了 `HitTestMode.None`，不会吃掉输入框的焦点。

```ts
import { GlassPanel } from '../ui/components/GlassPanel';

@Entry
@Component
struct Composer {
  @State isDark: boolean = false;
  @State cardW: number = 0;
  @State cardH: number = 0;

  build() {
    Stack() {
      // 你自己的底色 / 背景模糊层 —— 玻璃覆盖层只画边缘带，不抢这一层
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.isDark ? '#2a2a2e' : '#f2f3f5')
        .borderRadius(20)

      // 玻璃边缘覆盖层：尺寸必须与上面那层一致
      GlassPanel({
        isDark: this.isDark,
        panelWidth: this.cardW,      // @Prop @Watch：尺寸变了会延后 + 合并重烘
        panelHeight: this.cardH,
        panelRadius: 20,
        edgeOnly: true
      })
    }
    .width('100%')
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.cardW = Number(newArea.width);
      this.cardH = Number(newArea.height);
    })
  }
}
```

---

## API 参考

全部导出都在 `src/main/ets/core/glass/LiquidGlassBake.ets`（**零外部依赖**，只 import `@kit.ImageKit`）。

### 材质与预设

#### `class GlassMaterial`

材质参数集合。每个字段都对应原着色器的一个 uniform（或 uniform 分量）。

| 字段 | 默认值 | 对应 uniform / 来源 | 含义 |
| --- | --- | --- | --- |
| `diameterVp` | `36` | —（CPU 侧尺寸） | 圆形烘焙的直径（vp），渲染时乘 `dpr` |
| `dpr` | `2` | —（CPU 侧尺寸） | 设备像素比；`getUIContext().vp2px(1)` |
| `thickness` | `20` | `uOpticalProps.z` | 玻璃厚度（逻辑 px，内部按 `× dpr/3` 换算） |
| `refractiveIndex` | `1.2` | `uOpticalProps.x` | 折射率（球面透镜用 `1/n` 作 eta） |
| `chromaticAberration` | `0.01` | `uOpticalProps.y` | 折射带的色散比例 |
| `lightIntensity` | `0.5` | `uLightConfig.x` | 方向主光强度 |
| `ambientStrength` | `0.0` | `uLightConfig.y` | 环境光强度 |
| `saturation` | `1.5` | `uLightConfig.z` | 色相饱和（Rec.709 保亮度） |
| `lightAngle` | `0.75π` | `GlassDefaults.lightAngle` | 主光方向（弧度，光从左上来） |
| `ambientRim` | `0.0` | `uEdgeConfig.x` | 额外环带宽度（0 = 关） |
| `fresnelStrength` | `1.0` | `uEdgeConfig.y` | 菲涅尔边缘提亮强度 |
| `edgeAbsorption` | `0.0` | `uEdgeConfig.w` | 弯月面暗化强度（0 = 关） |
| `lensModel` | `0` | iOS 27 预设的透镜选择 | `0` = 球面（严格 Snell 折射），`1` = 视差（paraxial） |
| `glassColor` | `[1,1,1]` | `uGlassColor.rgb` | 染色 RGB（分量 ∈ [0,1]） |
| `glassColorA` | `0.0` | `uGlassColor.a` | 染色强度（0 = 不染色） |
| `whitenStrength` | `0.0` | `uWhiten` | 白化纱帘强度（0 = 无操作） |
| `whitenGated` | `true` | `uWhiten` | 白化是否按亮度门控（`smoothstep(0.40, 0.80, luma)`） |
| `rimShade` | `0.0` | `uRimConfig.x` | iOS 27 发丝暗线强度 |
| `rimShadeEnds` | `0.2` | `uRimConfig.z` | 发丝暗线两端的渐隐量 |
| `rimLight` | `0.0` | `uRimConfig.y` | 发丝内侧的边缘光强度 |

> 内部派生：`dprScale = dpr / 3`（即 `uEdgeConfig.z`）、`thicknessPx = thickness × dpr / 3`、
> `baseHeight = thicknessPx × 8`、`maxReach = 0.5 × min(physW, physH)`。

#### `ios27Material(diameterVp: number, dpr: number, isDark: boolean): GlassMaterial`

iOS 27 `glassEffect(.regular)` 材质的预设（对照 `LiquidGlassSettings.ios27Light` / `ios27Dark`）。
在平浅背景上你能看见的是**染色 + 弯月面 + 发丝暗线 + 边缘光**，折射本身是均匀的。要点：

- `glassColorA = isDark ? 0.12 : 0.53`（浅色是近白 `#F8F8F8`）
- `saturation = isDark ? 1.4 : 2.1`，`thickness = 32`，`refractiveIndex = 1.24`，`lensModel = 1`（paraxial）
- `lightAngle = isDark ? -π/2 : +π/2`（深色下光从下方来，浅色下从上）
- `lightIntensity = 0`、`fresnelStrength = 0`、`chromaticAberration = 0`、`edgeAbsorption = 0.035`
- `rimShade = isDark ? 0.45 : 1.0`、`rimShadeEnds = isDark ? 0 : 0.2`、`rimLight = isDark ? 1.15 : 1.0`

### 背景

#### `type BackdropSampler = (u: number, v: number) => number[]`

背景采样器，`u` / `v` 是整幅图的**归一化**坐标，返回 `[r, g, b]`（∈ [0,1]）。

#### `uniformBackdrop(r: number, g: number, b: number): BackdropSampler`

均匀背景 —— 玻璃浮在纯平页面上时用它（折射采到的就是它自己，效果逐像素等同真着色器）。
**这也是各种快路径成立的前提。**

### 烘焙入口

| 函数 | 返回 | 说明 |
| --- | --- | --- |
| `bakeGlassCircle(m: GlassMaterial, backdrop: BackdropSampler): image.PixelMap` | `RGBA_8888`、`UNPREMUL`、`editable` | 圆钮。物理尺寸 = `round(diameterVp × dpr)`，正方形 |
| `bakeGlassPanel(m, widthVp, heightVp, radiusVp, backdrop, overlay): image.PixelMap` | 同上 | 面板。物理尺寸 = `round(widthVp × dpr) × round(heightVp × dpr)`。**不做全局缓存**（尺寸变化由调用方自己判断） |
| `renderGlassBytes(m, backdrop): Uint8Array` | `width×height×4` 行优先 | 圆钮的裸字节，便于单测直接断言像素 |
| `renderPanelBytes(m, w, h, r, backdrop, overlay): Uint8Array` | 同上 | 面板的裸字节 |

`overlay`（面板的两种形态）：

- **`false` = 整块玻璃**：形状内部 alpha = 1，深内部填「代表像素跑一次完整链路」得到的常量色。
  自己就是一层不透明的玻璃板。
- **`true` = 边缘覆盖层**：只保留鼓边带，`alpha = geo.alpha × (1 - smoothstep(0.55, 1, 归一化高度))`，
  平顶深内部权重为 0（与快路径写的 0 同值，交界处无缝）。叠在你自己的底色 / 背景模糊之上，
  只贡献鼓边、发丝暗线和边缘光。

### 几何（单独导出，方便复用与单测）

| 导出 | 说明 |
| --- | --- |
| `fastPow(x: number, n: number): number` | `exp2(n × log2(max(x, 1e-4)))`，GLSL 内建 `pow` 的逐行对应（`sdf.glsl:99-101`） |
| `squircleShape(px, py, bx, by, zone, n): number` | Lamé 指数 `n` 的形状函数（`sdf.glsl:103-113`），内含直边 / 内区快路径 |
| `class SquircleShape` | `new SquircleShape(bx, by, r)` 一次算好 `zone` / `n`，`at(px, py)` 与 `sdfSquircle()` 逐位等价 |
| `sdfSquircle(px, py, bx, by, r): number` | 解析超椭圆 SDF（`sdf.glsl:128-135`）。`bx === by && r >= min(bx,by)` 时精确退化为圆 `hypot(px,py) - r` |

未导出的内部件：`GeometryPixel`、`geometryFromSamples`、`circleGeometry`、`panelGeometry`、
`GlassRenderCtx`、`renderGlassPixel` —— 圆与面板共用**同一条**渲染主链，不存在会漂移的第二份实现。

---

## 性能

**测量环境**：HarmonyOS PC 模拟器。一块 **1444 × 207 px** 的面板（约 **30 万像素**）。

| 阶段 | 一块面板 | 两块主题合计 |
| --- | --- | --- |
| 逐像素全算（基线） | **3.2 s** | **7.5 s** |
| 四条优化之后 | **0.6 s** | — |
| 提升 | **约 4×** | — |

**四条优化**（都不改变视觉输出）：

1. **深内部矩形跳算**：远离边缘的平台区连 SDF 都不算。
   形状铺满画布、只有四角被圆角切掉，切深 ≤ `rPx × (1 - 1/√2)`（圆角矩形的上界，超椭圆比它更「满」、切得更浅，所以这个界是保守的）。
   于是「离画布四边都 > `bandInner + 切深 + 1`」的点必在平台区 —— 长条面板上这块占了三分之二的像素。
   跳算内边界由几何反推：输出进平台区的条件是 `sdN ≤ -max(thicknessPx, smoothing/2)`，
   该 SDF 中心差分的 `|gradMag| ≤ 1.0001`，`sd` 侧取 1.05 倍作绝对裕量，**保证跳算的每个像素都已处于平台区**。
2. **`squircleShape` 的直边分支**：`m` 的某一分量为 0 时，Lamé 角 `(0ⁿ + 1ⁿ)^(1/n) ≡ 1`，`corner ≡ M` ——
   直边上的 SDF 就是到该边的欧氏距离。原式在直边照样跑三次 `fastPow`（6 次 `pow`/`log2`），
   实测这是整条烘焙链的绝对大头（3 秒级）。舍入差 ≤ 1e-13。
3. **形状参数提到循环外**：`zone` / `n` 只由 `(bx, by, r)` 决定，整块面板是常量，
   逐像素调用会多付一次 `log2`（30~65 万次调用）。
4. **直边整列 / 整行复用**：左 / 右直边（`|py| < by - zone`）上 `SDF = |px| - bx`、梯度 `= (±1, 0)`，
   整列几何相同 → 整列同色，每列只算一次、其余复制；上 / 下直边同理（整行同色）。
   **角区照旧逐像素**，并且补 5 次邻域采样。面板上约 95% 的边缘像素落在直边，而渲染链（每像素十来次 `pow`/`exp` + 小数组分配）是绝对大头。

**正确性**：优化是**逐字节等价**的 —— 面板左右镜像对称的单测（`renderPanelBytesMirrorSymmetricLeftRight`）
零失配，深内部 3×3 无缝，圆钮的每个像素值不允许回归。
剩下的 5 个面板用例（整块覆盖 / 覆盖层内部透明 / 深内部无缝 / 左右镜像 / 深浅主题像素不同）
就是给这条快路径立的门。

### 另一个坑：烘焙必须离开重绘路径

**同步烘焙会堵住重绘。** 烘图是 CPU 逐像素重活，如果直接同步跑在重绘之前，
新的尺寸就会被它一起堵住 —— 实测现象：窗口从半屏切全屏时，玻璃先是旧尺寸的长度，过一会儿才跳成新尺寸。

`GlassPanel` 里的处理（可以照抄）：

1. 尺寸变化的当帧**先按新尺寸画出去**（旧图被 `ImageFit.Fill` 拉伸填满，视觉上长度立刻跟上）；
2. 烘焙**延后 + 合并**：`scheduleBake()` 用 120 ms 的 debounce 定时器，拖拽 / 窗口动画连打只烘一次；
3. 两张主题的图分开烘：先烘用户正看着的那一张（这一拍只冻一半），另一张丢到下一拍（`setTimeout(..., 0)`）；
4. 圆整后的宽高没变就**不重烘**（`bakedW` / `bakedH` 比对）。

---

## 已知限制

- **backdrop 必须是常量，快路径才成立。** 深内部跳算与直边整列复用都假定背景在玻璃范围内是常量
  （把 `componentSnapshot` / 真实 backdrop 采样器传进 `backdrop` 会显出条带）。
  如果玻璃要压在有内容的背景上，快路径需要按 backdrop 的非均匀性重新设计。
- **未移植**（上游默认关闭、与本场景无关的独立子系统，移植了也只是死代码）：
  `uPinchStrength` 凹透镜横捏（iOS 26 胶囊指示器）、`uFrost` 霜化（需要 backdrop 的两趟模糊）、
  触摸镜面（`uTouchIntensity`）、平台视图穿透（`uPlatformViewMode`）。接口位置留着，需要时再补。
- **没有全局 PixelMap 缓存。** `bakeGlassPanel` 每次都重烘；缓存与失效由调用方负责
  （两个组件内部按尺寸做了最基本的「没变不重烘」）。
- **性能数字的语境**：模拟器比桌面 Node 慢 **25~40 倍**，真机上的数字会明显更小；
  上表是模拟器的保守值。首次烘焙会占用主线程数百毫秒（30 万像素面板），所以务必走上面的延后 + 合并。
- 面板 `radiusVp` 需要与调用方自己的 `borderRadius` 对齐，否则鼓边会跟可见圆角错位。
- 两个组件都接受 `backdropLight` / `backdropDark` 两个颜色 prop，**必须与真实背景一致**；
  改这两个 prop 不会自动触发重烘（只有面板尺寸变化会），主题色场景下它们是常量。

---

## 致谢与许可

- 着色器与视觉设计：**Sebastian Degenaar**（[pixel-innovations.com](https://pixel-innovations.com)），
  上游 **Tim Lehmann**（[whynotmake.it](https://whynotmake.it)）；
  代码来自 [`sdegenaar/liquid_glass_widgets`](https://github.com/sdegenaar/liquid_glass_widgets)（MIT）。
- 本仓库是**衍生移植**作品：原作者的版权声明与本仓库的许可一并以 **MIT** 提供，全文见 [LICENSE](LICENSE)。
- 再分发时请保留 `LICENSE` 中的三行版权声明（MIT 对衍生作品的要求）。
