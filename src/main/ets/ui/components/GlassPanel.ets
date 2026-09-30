/**
 * 液态玻璃面板（矩形卡）：玻璃本体是一张**烘焙出来的 PixelMap**（LiquidGlassBake，
 * 与 GlassCircle 同一套着色器逐行移植），形状是居中对称的圆角超椭圆（sdfSquircle）——
 * 鼓边 / 发丝暗线 / 边缘光就长在这层上。
 *
 * 默认 edgeOnly 形态：深内部透明，只画边缘带，盖在调用方自己的底色 / 背景模糊之上
 * （不抢调用方的填充层，也不会把卡片糊成一块实色）。要整块玻璃就传 edgeOnly:false。
 *
 * 本组件纯视觉，不处理点击：Image 挂 HitTestMode.None，不会吃掉输入框的焦点。
 *
 * 尺寸由调用方实测传入（panelWidth / panelHeight 是 @Prop，父状态变了会触发重烘）：
 * 圆整后的宽高没变不重烘（CPU 逐像素烘焙），深浅两份一次烘好，主题翻转直接取用。
 */

import { image } from '@kit.ImageKit';
import { bakeGlassPanel, ios27Material, uniformBackdrop } from '../../core/glass/LiquidGlassBake';

@Component
export struct GlassPanel {
  /** 深浅色：决定取哪一份烘好的图、以及用哪个背景采样色。@Prop 保证父组件翻转主题时重绘 */
  @Prop isDark: boolean = false;
  /** 面板宽（vp）。不能叫 width —— 会和通用 .width() 属性方法冲突（同 GlassCircle 的 size） */
  @Prop @Watch('onSizeChanged') panelWidth: number = 0;
  @Prop @Watch('onSizeChanged') panelHeight: number = 0;
  /** 面板圆角半径（vp），与调用方自己的 borderRadius 对齐。
   *  不能叫 cornerRadius —— 会和通用 .cornerRadius() 属性方法冲突（同 size / overlay） */
  panelRadius: number = 20;
  /** true = 边缘覆盖层（深内部透明，只画鼓边/发丝暗线/边缘光）；false = 整块玻璃。
   *  不能叫 overlay —— 会和通用 .overlay() 属性方法冲突 */
  edgeOnly: boolean = true;
  /** 面板底下是什么底色（uniformBackdrop 用）：浅色 / 深色各一个，必须与真实背景一致 */
  backdropLight: string = '#ffffff';
  backdropDark: string = '#1e1e22';

  /** 烘焙出来的玻璃图（浅 / 深 两份，主题翻转直接取） */
  @State panelLight: image.PixelMap | null = null;
  @State panelDark: image.PixelMap | null = null;
  /** 上次烘图用的圆整尺寸（vp）：宽高没变不重烘（烘焙是 CPU 逐像素，白烘会卡） */
  private bakedW: number = -1;
  private bakedH: number = -1;
  /** 合并定时器：拖拽 / 窗口动画会连续触发尺寸变化，停下来只烘一次 */
  private bakeTimer: number = -1;
  /** 另一张主题的图延后到下一拍烘，中间让 UI 喘口气（两张一起烘是一次两倍长的卡顿） */
  private otherTimer: number = -1;

  aboutToAppear(): void {
    // 首帧没有旧图可拉伸，直接烘
    this.bake();
  }

  aboutToDisappear(): void {
    if (this.bakeTimer >= 0) {
      clearTimeout(this.bakeTimer);
      this.bakeTimer = -1;
    }
    if (this.otherTimer >= 0) {
      clearTimeout(this.otherTimer);
      this.otherTimer = -1;
    }
  }

  onSizeChanged(): void {
    // 【性能坑】烘图是 CPU 逐像素重活，同步跑在重绘之前会把新尺寸的绘制一起堵住 ——
    // 实测现象：小窗切全屏时玻璃先是小窗长度，过一会儿才跳成全屏长度。
    // 所以：本帧先按新尺寸画（旧图被拉伸填满，长度立刻跟上），烘图延后 + 合并。
    this.scheduleBake();
  }

  /** 延后并合并烘图：先让本帧按新尺寸画出去，尺寸停稳后再烘 */
  private scheduleBake(): void {
    if (this.bakeTimer >= 0) {
      clearTimeout(this.bakeTimer);
    }
    this.bakeTimer = setTimeout((): void => {
      this.bakeTimer = -1;
      this.bake();
    }, 120);
  }

  private bake(): void {
    const w = Math.round(this.panelWidth);
    const h = Math.round(this.panelHeight);
    if (w <= 0 || h <= 0) {
      return;
    }
    if (w === this.bakedW && h === this.bakedH) {
      return;
    }
    this.bakedW = w;
    this.bakedH = h;
    // 先烘用户正看着的这一张（这一拍只冻一半），另一张主题的图放下一拍
    this.bakeTheme(this.isDark, w, h);
    if (this.otherTimer >= 0) {
      clearTimeout(this.otherTimer);
    }
    this.otherTimer = setTimeout((): void => {
      this.otherTimer = -1;
      this.bakeTheme(!this.isDark, Math.round(this.panelWidth), Math.round(this.panelHeight));
    }, 0);
  }

  /**
   * 烘一张主题的图（iOS 27 regular 材质，与 GlassCircle 同一套参数）：
   * 平浅背景上能看见的是染色 + 弯月面暗化 + 发丝暗线 + 边缘光。
   * dpr 与背景色默认值也照抄 GlassCircle（#ffffff / #1e1e22）—— 面板和那几颗按钮浮在同一块平底上。
   */
  private bakeTheme(isDark: boolean, w: number, h: number): void {
    const dpr = this.getUIContext().vp2px(1);
    const bg = hexToRgb01(isDark ? this.backdropDark : this.backdropLight);
    // diameterVp 只被圆形烘焙用到，面板尺寸走 widthVp/heightVp/radiusVp，这里给个占位值即可
    const map = bakeGlassPanel(ios27Material(30, dpr, isDark), w, h, this.panelRadius,
      uniformBackdrop(bg[0], bg[1], bg[2]), this.edgeOnly);
    if (isDark) {
      this.panelDark = map;
    } else {
      this.panelLight = map;
    }
  }

  build() {
    Stack() {
      // 深浅两份图都直接渲染（不走 @Builder 值参数：值参数不参与刷新，
      // 主题翻转后旧图会一直挂着 —— 实测踩坑：切深色后按钮还是浅色那张）。
      if (this.isDark && this.panelDark !== null) {
        Image(this.panelDark)
          .width(this.panelWidth)
          .height(this.panelHeight)
          .objectFit(ImageFit.Fill)
          .hitTestBehavior(HitTestMode.None)
      }
      if (!this.isDark && this.panelLight !== null) {
        Image(this.panelLight)
          .width(this.panelWidth)
          .height(this.panelHeight)
          .objectFit(ImageFit.Fill)
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width(this.panelWidth)
    .height(this.panelHeight)
  }
}

/** '#RRGGBB' → [r,g,b] ∈ [0,1]（uniformBackdrop 用；与 GlassCircle 同一套） */
function hexToRgb01(hex: string): number[] {
  const v = parseInt(hex.substring(1), 16);
  return [((v >> 16) & 0xff) / 255, ((v >> 8) & 0xff) / 255, (v & 0xff) / 255];
}
