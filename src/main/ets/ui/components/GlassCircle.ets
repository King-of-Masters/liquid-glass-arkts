/**
 * 液态玻璃圆钮：玻璃本体是一张**烘焙出来的 PixelMap**（LiquidGlassBake，对着色器逐行移植的
 * CPU 烘焙），不是渐变叠出来的近似 —— 折射/色散/染色/边缘光/菲涅尔全在着色器逻辑里。
 * 上面那层内容由调用方通过 content 插槽自己叠（本包不依赖任何图标组件）。
 *
 * 本组件纯视觉，不处理点击：调用方自己包 Pressable / 空容器挂 onClick，
 * 免得子节点把点击事件吃掉（需要按压回弹的按钮要自己保留 Pressable）。
 *
 * 烘焙只发生在 aboutToAppear（CPU，~ms 级）：深浅两份一次烘好，主题翻转直接取用，
 * 不在 build 里做写入/重烘（build 只允许一个根节点，顺带避免无谓重建）。
 */

import { image } from '@kit.ImageKit';
import { bakeGlassCircle, ios27Material, uniformBackdrop } from '../../core/glass/LiquidGlassBake';

@Component
export struct GlassCircle {
  /** 深浅色：决定取哪一份烘好的图、以及用哪个背景采样色。@Prop 保证父组件翻转主题时重绘 */
  @Prop isDark: boolean = false;
  /** 直径（vp）。不能叫 size —— 会和 CustomComponent 基类的 .size() 属性方法冲突（编译不过） */
  diameter: number = 30;
  /** 投影强度：贴在卡片里的按钮可以调小，浮在页面上的调大 */
  shadowRadius: number = 12;
  /** 投影颜色 */
  shadowColor: string = '#99000000';
  /** 玻璃片底下是什么底色（uniformBackdrop 用）：浅色 / 深色各一个，必须与真实背景一致 */
  backdropLight: string = '#ffffff';
  backdropDark: string = '#1e1e22';

  /** 烘焙出来的玻璃图（浅 / 深 两份，主题翻转直接取） */
  @State glassLight: image.PixelMap | null = null;
  @State glassDark: image.PixelMap | null = null;

  /** 图标插槽的默认实现：什么都不画 */
  @Builder
  emptySlot() {
  }

  /** 叠在玻璃之上的内容（一般是一个图标），由调用方传 @Builder 进来 */
  @BuilderParam content: () => void = this.emptySlot;

  aboutToAppear(): void {
    // 深浅两份一次烘好（iOS 27 regular 材质：这是那类按钮本来就用的那套参数，
    // 在平浅背景上也能看见 —— 玻璃体的 53% 近白染色 + 弯月面暗化 + 发丝暗线 + 边缘光）
    const dpr = this.getUIContext().vp2px(1);
    const bgLight = hexToRgb01(this.backdropLight);
    const bgDark = hexToRgb01(this.backdropDark);
    const mLight = ios27Material(this.diameter, dpr, false);
    const mDark = ios27Material(this.diameter, dpr, true);
    this.glassLight = bakeGlassCircle(mLight, uniformBackdrop(bgLight[0], bgLight[1], bgLight[2]));
    this.glassDark = bakeGlassCircle(mDark, uniformBackdrop(bgDark[0], bgDark[1], bgDark[2]));
  }

  build() {
    Stack() {
      // 深浅两份图都直接渲染（不走 @Builder 值参数：值参数不参与刷新，
      // 主题翻转后旧图会一直挂着 —— 实测踩坑：切深色后按钮还是浅色那张）。
      if (this.isDark && this.glassDark !== null) {
        Image(this.glassDark)
          .width(this.diameter)
          .height(this.diameter)
          .objectFit(ImageFit.Fill)
      }
      if (!this.isDark && this.glassLight !== null) {
        Image(this.glassLight)
          .width(this.diameter)
          .height(this.diameter)
          .objectFit(ImageFit.Fill)
      }
      this.content()
    }
    .width(this.diameter)
    .height(this.diameter)
    .borderRadius(this.diameter / 2)
    .shadow({ radius: this.shadowRadius, color: this.shadowColor, offsetY: 3 })
  }
}

/** '#RRGGBB' → [r,g,b] ∈ [0,1]（uniformBackdrop 用） */
function hexToRgb01(hex: string): number[] {
  const v = parseInt(hex.substring(1), 16);
  return [((v >> 16) & 0xff) / 255, ((v >> 8) & 0xff) / 255, (v & 0xff) / 255];
}
