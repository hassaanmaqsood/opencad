/**
 * @file bottom_lenses.ts
 * Wave 14: Bottom "Lenses & Timeline" Bar.
 * Replaces workbench rooms with composable toggleable viewport overlays:
 * Section A-A, FEA/Flexures, Sheet Metal Unfold, 2D Blueprint, 3MF/CAM,
 * and Kinematic Assembly Motion / Exploded View scrubber.
 */

export interface LensState {
  section: boolean;
  fea: boolean;
  sheetmetal: boolean;
  drawing: boolean;
  mfg: boolean;
  zebra: boolean;
}

export interface BottomLensesOptions {
  container?: HTMLElement;
  onToggleLens: (lens: keyof LensState, active: boolean) => void;
  onExplodeChange: (factor: number) => void;
  onMotionChange: (angleDeg: number) => void;
}

export class BottomLensesBar {
  private container: HTMLElement;
  private options: BottomLensesOptions;
  private lensStates: LensState = {
    section: false,
    fea: false,
    sheetmetal: false,
    drawing: false,
    mfg: false,
    zebra: false,
  };

  private isPlayingMotion: boolean = false;
  private animFrameId: number | null = null;
  private currentMotionAngle: number = 0;

  constructor(options: BottomLensesOptions) {
    this.options = options;
    this.container = options.container || document.createElement('div');
    this.container.id = 'bottom-lenses-bar';
    this.container.className = 'bottom-lenses-bar hud-panel';
    this.container.setAttribute('data-testid', 'bottom-lenses-bar');

    if (!options.container) {
      const app = document.getElementById('app-container') || document.body;
      app.appendChild(this.container);
    }

    this.render();
    this.setupListeners();
  }

  public getElement(): HTMLElement {
    return this.container;
  }

  private render(): void {
    this.container.innerHTML = `
      <div class="lenses-group" data-testid="lenses-group">
        <span class="lenses-label">Lenses:</span>
        <button id="lens-section" class="lens-pill-btn" data-testid="lens-section" title="Toggle 3D Section Plane with hatched caps">
          <span class="lens-icon">✂️</span> Section A-A
        </button>
        <button id="lens-fea" class="lens-pill-btn" data-testid="lens-fea" title="Overlay FEA Von Mises stress and FACT compliance">
          <span class="lens-icon">🔥</span> FEA & Flexure
        </button>
        <button id="lens-sheetmetal" class="lens-pill-btn" data-testid="lens-sheetmetal" title="Overlay or split DIN 6935 2D flat pattern">
          <span class="lens-icon">📐</span> Unfold Sheet
        </button>
        <button id="lens-drawing" class="lens-pill-btn" data-testid="lens-drawing" title="Open synchronized associative 2D drawing sheet">
          <span class="lens-icon">📝</span> 2D Blueprint
        </button>
        <button id="lens-mfg" class="lens-pill-btn" data-testid="lens-mfg" title="Overlay 3MF build volume & CNC CAM toolpaths">
          <span class="lens-icon">🛠️</span> 3MF & CAM
        </button>
        <button id="lens-zebra" class="lens-pill-btn" data-testid="lens-zebra" title="Inspect surface curvature continuity">
          <span class="lens-icon">🦓</span> Zebra
        </button>
      </div>

      <div class="timeline-scrubber-group" data-testid="timeline-scrubber-group">
        <div class="scrubber-item">
          <label for="assembly-explode-scrubber" class="scrubber-label">Explode:</label>
          <input type="range" id="assembly-explode-scrubber" data-testid="assembly-explode-scrubber" data-role="explode-slider" min="0" max="100" value="0" />
        </div>
        <div class="scrubber-item">
          <button id="btn-motion-play" class="btn-motion-play" data-testid="btn-motion-play" data-role="btn-play-motion" title="Play kinematic motion simulation">▶</button>
          <label for="assembly-motion-scrubber" class="scrubber-label">Motion:</label>
          <input type="range" id="assembly-motion-scrubber" data-testid="assembly-motion-scrubber" min="0" max="360" value="0" />
          <span class="motion-angle-readout" id="motion-angle-readout">0°</span>
        </div>
      </div>
    `;
  }

  private setupListeners(): void {
    const bindLens = (btnId: string, lensKey: keyof LensState) => {
      const btn = this.container.querySelector(`#${btnId}`) as HTMLElement | null;
      btn?.addEventListener('click', () => {
        this.lensStates[lensKey] = !this.lensStates[lensKey];
        btn.classList.toggle('active', this.lensStates[lensKey]);
        this.options.onToggleLens(lensKey, this.lensStates[lensKey]);
      });
    };

    bindLens('lens-section', 'section');
    bindLens('lens-fea', 'fea');
    bindLens('lens-sheetmetal', 'sheetmetal');
    bindLens('lens-drawing', 'drawing');
    bindLens('lens-mfg', 'mfg');
    bindLens('lens-zebra', 'zebra');

    // Explode Scrubber
    const explodeSlider = this.container.querySelector('#assembly-explode-scrubber') as HTMLInputElement | null;
    explodeSlider?.addEventListener('input', () => {
      const factor = parseFloat(explodeSlider.value) / 100.0;
      this.options.onExplodeChange(factor);
    });

    // Motion Scrubber & Play/Pause
    const motionSlider = this.container.querySelector('#assembly-motion-scrubber') as HTMLInputElement | null;
    const motionReadout = this.container.querySelector('#motion-angle-readout') as HTMLElement | null;
    const playBtn = this.container.querySelector('#btn-motion-play') as HTMLElement | null;

    motionSlider?.addEventListener('input', () => {
      const angle = parseFloat(motionSlider.value);
      this.currentMotionAngle = angle;
      if (motionReadout) motionReadout.innerText = `${Math.round(angle)}°`;
      this.options.onMotionChange(angle);
    });

    playBtn?.addEventListener('click', () => {
      this.isPlayingMotion = !this.isPlayingMotion;
      playBtn.innerText = this.isPlayingMotion ? '⏸' : '▶';
      playBtn.classList.toggle('playing', this.isPlayingMotion);

      if (this.isPlayingMotion) {
        const step = () => {
          if (!this.isPlayingMotion) return;
          this.currentMotionAngle = (this.currentMotionAngle + 2) % 360;
          if (motionSlider) motionSlider.value = this.currentMotionAngle.toString();
          if (motionReadout) motionReadout.innerText = `${Math.round(this.currentMotionAngle)}°`;
          this.options.onMotionChange(this.currentMotionAngle);
          this.animFrameId = requestAnimationFrame(step);
        };
        this.animFrameId = requestAnimationFrame(step);
      } else if (this.animFrameId) {
        cancelAnimationFrame(this.animFrameId);
        this.animFrameId = null;
      }
    });
  }

  public setLensActive(lensKey: keyof LensState, active: boolean): void {
    this.lensStates[lensKey] = active;
    const btn = this.container.querySelector(`#lens-${lensKey}`) as HTMLElement | null;
    btn?.classList.toggle('active', active);
    this.options.onToggleLens(lensKey, active);
  }
}
