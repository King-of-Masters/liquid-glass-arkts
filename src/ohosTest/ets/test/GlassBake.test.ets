/**
 * 液态玻璃烘焙（LiquidGlassBake）的像素级单测 —— 从应用工程里抽出来的独立测试文件。
 *
 * 覆盖三层：
 *   1. 渲染链（renderGlassBytes）：深浅两套材质烘出来的体色/边缘像素是否落在预期带内；
 *   2. 几何（sdfSquircle）：超椭圆 SDF 的退化、对称性、符号语义、沿 45° 射线的单调性；
 *   3. 面板（renderPanelBytes）：整块玻璃 / 边缘覆盖层两种形态，以及快路径（直边整列复用、
 *      深内部跳算）不产生接缝、左右严格镜像。
 *
 * 注册方式：在工程的测试入口（如 src/test/List.test.ets）import 并调用本函数。
 * import 路径按本包目录结构写死为 ../../../main/ets/core/glass/LiquidGlassBake；
 * 若你把本文件放进 entry/src/test/，改成 ../main/ets/core/glass/LiquidGlassBake 即可。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  ios27Material,
  renderGlassBytes,
  renderPanelBytes,
  sdfSquircle,
  uniformBackdrop
} from '../../../main/ets/core/glass/LiquidGlassBake';

export default function glassBakeTest() {
  describe('glassBakeTest', () => {

    it('glassBakeProducesThemeCorrectPixels', 0, () => {
      // 液态玻璃烘焙（着色器逐行移植）的回归门：
      // 浅色背景烘出近白、深色背景烘出深色 —— 对应"深色模式下玻璃片发白"这个实测踩坑。
      // 60px 图（30vp @ dpr2）：中心不透明、圆外全透明、深色下背光侧边缘比体色亮。
      const light = renderGlassBytes(ios27Material(30, 2, false), uniformBackdrop(1, 1, 1));
      const dark = renderGlassBytes(ios27Material(30, 2, true), uniformBackdrop(0.118, 0.118, 0.133));
      const mid = (30 * 60 + 30) * 4;
      expect(light[mid + 3]).assertEqual(255);        // 中心不透明
      expect(dark[mid + 3]).assertEqual(255);
      expect(light[mid]).assertLarger(240);           // 浅色体：近白
      expect(dark[mid]).assertLargerOrEqual(40);      // 深色体：约 57
      expect(dark[mid]).assertLess(110);
      expect(light[3]).assertEqual(0);                // 圆外透明（左上角）
      expect(dark[3]).assertEqual(0);
      // 深色下光从下方来（lightAngle = -π/2）：底缘是迎光侧，应比体色亮（rim light）
      const bottomRim = (56 * 60 + 30) * 4;
      expect(dark[bottomRim]).assertLarger(dark[mid]);
    });

    // ========== 超椭圆 SDF / 面板玻璃（鼓边覆盖层） ==========

    it('sdfSquircleDegradesToCircleWhenRadiusEqualsBoxHalf', 0, () => {
      // 防回归：r = bx = by 时超椭圆必须退化成标准圆（zone 钳到 r、n=2），
      // 误差口径直接对标 Math.hypot(px,py) - r —— 鼓边几何的正确性锚点。
      const r = 40;
      // 轴上点（恰在圆上）、45° 点（恰在圆上）、内部点、原点、外部点
      const samples: number[][] = [
        [40, 0], [0, 40], [-40, 0], [0, -40],
        [28.2842712474619, 28.2842712474619],
        [20, 20], [-12, 30], [0, 0],
        [80, 0], [-30, -54]
      ];
      for (const p of samples) {
        const got = sdfSquircle(p[0], p[1], r, r, r);
        const want = Math.hypot(p[0], p[1]) - r;
        expect(Math.abs(got - want)).assertLess(1e-3);
      }
    });

    it('sdfSquircleSymmetricAboutAxesAndSignedInsideOutside', 0, () => {
      // 防回归：SDF 必须关于 x/y 轴对称（法线/鼓边亮度不许随象限翻转），
      // 且保持符号语义：中心在内为负、盒外远处为正（alpha 与着色都靠它分内外。
      const bx = 40, by = 20, r = 12;
      const q1 = sdfSquircle(7, 13, bx, by, r);
      expect(sdfSquircle(7, -13, bx, by, r)).assertEqual(q1);   // x 轴镜像
      expect(sdfSquircle(-7, 13, bx, by, r)).assertEqual(q1);   // y 轴镜像
      expect(sdfSquircle(-7, -13, bx, by, r)).assertEqual(q1);  // 对角镜像
      const q2 = sdfSquircle(23, 5, bx, by, r);
      expect(sdfSquircle(23, -5, bx, by, r)).assertEqual(q2);
      expect(sdfSquircle(-23, 5, bx, by, r)).assertEqual(q2);
      expect(sdfSquircle(-23, -5, bx, by, r)).assertEqual(q2);

      expect(sdfSquircle(0, 0, bx, by, r)).assertLess(0);             // 中心在内部
      expect(sdfSquircle(bx * 2, by * 2, bx, by, r)).assertLarger(0); // 盒外远处角上
    });

    it('sdfSquircleMonotonicSingleZeroAlong45DegreeRay', 0, () => {
      // 防回归：沿 45° 从盒心向外 SDF 必须单调递增、且只过一次零点 ——
      // 边缘带归一化高度、发丝暗线的 smoothstep 都假设「越往外 SDF 越大」。
      const bx = 40, by = 40, r = 20;
      const values: number[] = [];
      for (let s = 0; s <= 80; s += 4) {
        values.push(sdfSquircle(s, s, bx, by, r)); // (s, s) 即 45° 射线
      }
      for (let i = 1; i < values.length; i++) {
        expect(values[i] - values[i - 1]).assertLargerOrEqual(0); // 相邻差值 >= 0
      }
      expect(values[0]).assertLess(0);
      expect(values[values.length - 1]).assertLarger(0);
      let crossings = 0;
      for (let i = 1; i < values.length; i++) {
        if (values[i - 1] < 0 && values[i] >= 0) {
          crossings++;
        }
      }
      expect(crossings).assertEqual(1); // 符号只翻转一次
    });

    it('renderPanelBytesFullGlassCoversShapeAndClearsOutside', 0, () => {
      // 防回归：overlay=false 整块玻璃 —— 字节数按物理像素算、中心不透明、
      // 圆角超椭圆外透明（寻址/尺寸算错会整块花屏或内容缩成一角）。
      const bytes = renderPanelBytes(ios27Material(200, 2, false), 200, 80, 20,
        uniformBackdrop(1, 1, 1), false);
      const wPx = 400, hPx = 160; // 200vp × 80vp @ dpr 2
      expect(bytes.length).assertEqual(wPx * hPx * 4);
      const mid = (80 * wPx + 200) * 4;
      expect(bytes[mid + 3]).assertEqual(255); // 中心不透明
      expect(bytes[3]).assertEqual(0);         // (0,0) 角落落在圆角外
    });

    it('renderPanelBytesOverlayKeepsInteriorClearAndPaintsEdgeBand', 0, () => {
      // 防回归：overlay=true 边缘覆盖层 —— 深内部必须全透明（叠在真背景上
      // 不许糊住内容），鼓边带必须有 alpha>0（水表面张力看得见的部分）。
      const bytes = renderPanelBytes(ios27Material(200, 2, false), 200, 80, 20,
        uniformBackdrop(1, 1, 1), true);
      const wPx = 400;
      const mid = (80 * wPx + 200) * 4;
      expect(bytes[mid + 3]).assertEqual(0); // 中心深内部：全透明
      // 沿中线从中心向右缘扫：鼓边带应出现 alpha>0 的像素
      let edgeAlpha = 0;
      for (let x = 200; x < wPx; x++) {
        const a = bytes[(80 * wPx + x) * 4 + 3];
        if (a > 0) {
          edgeAlpha = a;
          break;
        }
      }
      expect(edgeAlpha).assertLarger(0); // 找得到鼓边带
    });

    it('renderPanelBytesDeepInteriorUniformWithoutSeam', 0, () => {
      // 防回归：快路径（uniformBackdrop）下深内部必须逐像素完全一致 ——
      // 中心 3×3 邻域任何通道出现接缝 = 快慢路径或深浅分支对不齐。
      const bytes = renderPanelBytes(ios27Material(200, 2, false), 200, 80, 20,
        uniformBackdrop(1, 1, 1), false);
      const wPx = 400;
      const base = (80 * wPx + 200) * 4;
      for (let dy = -1; dy <= 1; dy++) {
        for (let dx = -1; dx <= 1; dx++) {
          const o = ((80 + dy) * wPx + 200 + dx) * 4;
          expect(bytes[o]).assertEqual(bytes[base]);
          expect(bytes[o + 1]).assertEqual(bytes[base + 1]);
          expect(bytes[o + 2]).assertEqual(bytes[base + 2]);
          expect(bytes[o + 3]).assertEqual(bytes[base + 3]);
        }
      }
    });

    it('renderPanelBytesMirrorSymmetricLeftRight', 0, () => {
      // 防回归：光照是垂直方向的（lightAngle = ±π/2），左右两边的鼓边/发丝线/边缘光
      // 必须逐像素完全一致。直边带快路径是「每列算一次、整列复制」，一旦列色取错列
      // 或角区与直边带的交界处理不齐，这里就会左右对不上。
      const bytes = renderPanelBytes(ios27Material(200, 2, false), 200, 80, 20,
        uniformBackdrop(1, 1, 1), true);
      const wPx = 400, hPx = 160;
      let mismatches = 0;
      for (let y = 0; y < hPx; y++) {
        for (let x = 0; x < wPx; x++) {
          const o = (y * wPx + x) * 4;
          const m = (y * wPx + (wPx - 1 - x)) * 4;
          if (bytes[o] !== bytes[m] || bytes[o + 1] !== bytes[m + 1]
            || bytes[o + 2] !== bytes[m + 2] || bytes[o + 3] !== bytes[m + 3]) {
            mismatches++;
          }
        }
      }
      expect(mismatches).assertEqual(0);
    });

    it('renderPanelBytesLightDarkThemePixelsDiffer', 0, () => {
      // 防回归：深浅色主题烘出的面板像素必须不同（对应"深色模式下玻璃片发白"
      // 这个实测踩坑）—— 沿用 glassBakeProducesThemeCorrectPixels 的口径。
      const light = renderPanelBytes(ios27Material(200, 2, false), 200, 80, 20,
        uniformBackdrop(1, 1, 1), false);
      const dark = renderPanelBytes(ios27Material(200, 2, true), 200, 80, 20,
        uniformBackdrop(0.118, 0.118, 0.133), false);
      const mid = (80 * 400 + 200) * 4;
      const differ = light[mid] !== dark[mid] || light[mid + 1] !== dark[mid + 1]
        || light[mid + 2] !== dark[mid + 2] || light[mid + 3] !== dark[mid + 3];
      expect(differ).assertTrue();             // 至少一个通道不等
      expect(light[mid]).assertLarger(240);      // 浅色体：近白
      expect(dark[mid]).assertLargerOrEqual(40); // 深色体：约 57
      expect(dark[mid]).assertLess(110);
    });
  });
}
