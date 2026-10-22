import { CadFeatureNode } from '../types/cad';

export interface TimelineBarOptions {
  container: HTMLElement;
  initialNodes: CadFeatureNode[];
  initialRollbackIndex?: number;
  onRollbackChange: (index: number) => void;
}

export class TimelineBar {
  private container: HTMLElement;
  private nodes: CadFeatureNode[];
  private rollbackIndex: number;
  private onRollbackChange: (index: number) => void;

  private isDragging: boolean = false;
  private scrubberEl: HTMLElement | null = null;
  private trackEl: HTMLElement | null = null;

  constructor(options: TimelineBarOptions) {
    this.container = options.container;
    this.nodes = [...options.initialNodes];
    this.rollbackIndex = options.initialRollbackIndex ?? (this.nodes.length - 1);
    this.onRollbackChange = options.onRollbackChange;

    this.container.classList.add('opencad-timeline-bar');
    this.container.setAttribute('data-testid', 'timeline-bar');

    this.render();
  }

  public setNodes(nodes: CadFeatureNode[], rollbackIndex?: number): void {
    this.nodes = [...nodes];
    if (rollbackIndex !== undefined) {
      this.rollbackIndex = Math.max(0, Math.min(rollbackIndex, this.nodes.length - 1));
    } else if (this.rollbackIndex >= this.nodes.length) {
      this.rollbackIndex = Math.max(0, this.nodes.length - 1);
    }
    this.render();
  }

  public setRollbackIndex(index: number): void {
    const clamped = Math.max(0, Math.min(index, this.nodes.length - 1));
    if (this.rollbackIndex !== clamped) {
      this.rollbackIndex = clamped;
      this.render();
      this.onRollbackChange(this.rollbackIndex);
    }
  }

  public getRollbackIndex(): number {
    return this.rollbackIndex;
  }

  private render(): void {
    this.container.innerHTML = '';

    // 1. Controls Group (Step back, Play, Step forward)
    const controls = document.createElement('div');
    controls.className = 'timeline-controls';

    const stepBackBtn = document.createElement('button');
    stepBackBtn.className = 'timeline-ctrl-btn';
    stepBackBtn.title = 'Step Backward';
    stepBackBtn.innerText = '⏮';
    stepBackBtn.setAttribute('data-testid', 'timeline-step-back');
    stepBackBtn.addEventListener('click', () => {
      if (this.rollbackIndex > 0) {
        this.setRollbackIndex(this.rollbackIndex - 1);
      }
    });

    const stepForwardBtn = document.createElement('button');
    stepForwardBtn.className = 'timeline-ctrl-btn';
    stepForwardBtn.title = 'Step Forward';
    stepForwardBtn.innerText = '⏭';
    stepForwardBtn.setAttribute('data-testid', 'timeline-step-forward');
    stepForwardBtn.addEventListener('click', () => {
      if (this.rollbackIndex < this.nodes.length - 1) {
        this.setRollbackIndex(this.rollbackIndex + 1);
      }
    });

    controls.appendChild(stepBackBtn);
    controls.appendChild(stepForwardBtn);
    this.container.appendChild(controls);

    // 2. Timeline Track with Feature Markers
    const track = document.createElement('div');
    track.className = 'timeline-track';
    track.setAttribute('data-testid', 'timeline-track');
    this.trackEl = track;

    this.nodes.forEach((node, index) => {
      const isPast = index <= this.rollbackIndex;
      const marker = document.createElement('div');
      marker.className = `timeline-node ${isPast ? 'active' : 'rolled-back'} ${node.is_suppressed ? 'suppressed' : ''}`;
      marker.setAttribute('data-feature-id', String(node.feature_id));
      marker.setAttribute('data-index', String(index));
      marker.setAttribute('data-testid', `timeline-node-${index}`);

      let icon = '📦';
      if (node.name.toLowerCase().includes('sketch')) icon = '✏️';
      else if (node.name.toLowerCase().includes('extrude')) icon = '⬆️';
      else if (node.name.toLowerCase().includes('fillet')) icon = '🪚';
      else if (node.name.toLowerCase().includes('chamfer')) icon = '📐';
      else if (node.name.toLowerCase().includes('cut') || node.name.toLowerCase().includes('hole')) icon = '🕳️';

      marker.innerHTML = `
        <span class="timeline-node-icon">${icon}</span>
        <span class="timeline-node-name">${node.name}</span>
      `;

      marker.addEventListener('click', () => {
        this.setRollbackIndex(index);
      });

      track.appendChild(marker);
    });

    // 3. Rollback Scrubber Handle
    const scrubber = document.createElement('div');
    scrubber.className = 'timeline-scrubber';
    scrubber.setAttribute('data-testid', 'timeline-scrubber');
    scrubber.title = 'Drag to rollback history';
    this.scrubberEl = scrubber;

    this.setupScrubberEvents(scrubber, track);
    track.appendChild(scrubber);

    this.container.appendChild(track);
    this.positionScrubber();
  }

  private positionScrubber(): void {
    if (!this.trackEl || !this.scrubberEl) return;
    const nodeEls = this.trackEl.querySelectorAll<HTMLElement>('.timeline-node');
    if (nodeEls.length === 0) return;

    const targetEl = nodeEls[this.rollbackIndex] || nodeEls[nodeEls.length - 1];
    const trackRect = this.trackEl.getBoundingClientRect();
    const targetRect = targetEl.getBoundingClientRect();

    if (trackRect.width > 0) {
      const offset = (targetRect.right - trackRect.left);
      this.scrubberEl.style.left = `${offset}px`;
    }
  }

  private setupScrubberEvents(scrubber: HTMLElement, track: HTMLElement): void {
    scrubber.addEventListener('pointerdown', (e) => {
      e.preventDefault();
      this.isDragging = true;
      scrubber.setPointerCapture(e.pointerId);
    });

    scrubber.addEventListener('pointermove', (e) => {
      if (!this.isDragging) return;
      const trackRect = track.getBoundingClientRect();
      const clientX = e.clientX;
      const relX = clientX - trackRect.left;

      const nodeEls = Array.from(track.querySelectorAll<HTMLElement>('.timeline-node'));
      let closestIdx = 0;
      let minDistance = Infinity;

      nodeEls.forEach((el, idx) => {
        const r = el.getBoundingClientRect();
        const center = (r.left + r.right) / 2 - trackRect.left;
        const dist = Math.abs(relX - center);
        if (dist < minDistance) {
          minDistance = dist;
          closestIdx = idx;
        }
      });

      if (closestIdx !== this.rollbackIndex) {
        this.setRollbackIndex(closestIdx);
      }
    });

    scrubber.addEventListener('pointerup', (e) => {
      if (this.isDragging) {
        this.isDragging = false;
        try {
          scrubber.releasePointerCapture(e.pointerId);
        } catch (_) {}
      }
    });
  }
}
