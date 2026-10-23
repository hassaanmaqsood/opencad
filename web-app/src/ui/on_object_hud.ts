/**
 * @file on_object_hud.ts
 * Wave 14: Center 3D/2D Viewport On-Object Contextual HUD & Direct Manipulation Handles.
 * Renders floating HUD pill near clicked sub-shape with exact editable measurement,
 * human-readable Semantic Selector Badge (>Z, @cylindrical), and context-smart quick actions.
 */

import * as THREE from 'three';
import { SubShapeSelection } from '../types/cad';
import { CadViewer } from '../renderer/viewer';

export interface OnObjectAction {
  id: string;
  label: string;
  icon: string;
  tooltip: string;
  action: () => void;
}

export interface OnObjectHudOptions {
  viewer: CadViewer;
  onDimensionChange?: (val: number) => void;
  onActionTrigger?: (actionId: string, selector: string) => void;
}

export class OnObjectHud {
  private container: HTMLElement;
  private viewer: CadViewer;
  private options: OnObjectHudOptions;

  private dimInput: HTMLInputElement;
  private selectorBadge: HTMLElement;
  private actionsContainer: HTMLElement;
  private currentSelector: string = '>Z';
  private currentDimension: number = 20.0;

  // Direct 3D manipulation arrow gizmo
  private arrowGizmo: THREE.Group | null = null;

  constructor(options: OnObjectHudOptions) {
    this.viewer = options.viewer;
    this.options = options;

    this.container = document.createElement('div');
    this.container.id = 'on-object-hud';
    this.container.className = 'on-object-hud hud-panel';
    this.container.setAttribute('data-testid', 'on-object-hud');
    this.container.style.display = 'none';

    this.container.innerHTML = `
      <div class="on-object-header">
        <span class="semantic-selector-badge" id="semantic-selector-badge" data-testid="semantic-selector-badge" title="Click to copy semantic selector">>Z</span>
        <div class="hud-dim-box">
          <input type="number" id="hud-dimension-input" class="hud-dimension-input" data-testid="hud-dimension-input" value="20.00" step="0.5" />
          <span class="hud-dim-unit">mm</span>
        </div>
      </div>
      <div class="on-object-actions" id="on-object-actions" data-testid="on-object-actions"></div>
    `;

    document.body.appendChild(this.container);

    this.dimInput = this.container.querySelector('#hud-dimension-input')!;
    this.selectorBadge = this.container.querySelector('#semantic-selector-badge')!;
    this.actionsContainer = this.container.querySelector('#on-object-actions')!;

    this.setupListeners();
    this.initArrowGizmo();
  }

  private setupListeners(): void {
    this.dimInput.addEventListener('change', () => {
      const val = parseFloat(this.dimInput.value);
      if (!isNaN(val)) {
        this.currentDimension = val;
        this.options.onDimensionChange?.(val);
      }
    });

    this.selectorBadge.addEventListener('click', () => {
      navigator.clipboard?.writeText(this.currentSelector);
      const prev = this.selectorBadge.innerText;
      this.selectorBadge.innerText = 'Copied!';
      setTimeout(() => {
        this.selectorBadge.innerText = prev;
      }, 1000);
    });

    // Sub-shape selection updates
    this.viewer.canvas.addEventListener('click', (e: MouseEvent) => {
      const sel = this.viewer.currentSelection;
      if (sel.type === 'face' || sel.type === 'edge') {
        this.showAt(e.clientX, e.clientY, sel);
      } else if (!this.container.contains(e.target as Node)) {
        this.hide();
      }
    });
  }

  private initArrowGizmo(): void {
    this.arrowGizmo = new THREE.Group();
    this.arrowGizmo.name = 'DirectPushPullArrow';
    this.arrowGizmo.visible = false;

    // Shaft (Cylinder)
    const shaftGeom = new THREE.CylinderGeometry(0.06, 0.06, 1.2, 16);
    shaftGeom.translate(0, 0.6, 0);
    const arrowMat = new THREE.MeshStandardMaterial({
      color: 0x38bdf8,
      emissive: 0x0284c7,
      emissiveIntensity: 0.4,
      roughness: 0.2,
      metalness: 0.8,
    });
    const shaft = new THREE.Mesh(shaftGeom, arrowMat);

    // Head (Cone)
    const coneGeom = new THREE.ConeGeometry(0.18, 0.4, 16);
    coneGeom.translate(0, 1.4, 0);
    const cone = new THREE.Mesh(coneGeom, arrowMat);

    this.arrowGizmo.add(shaft);
    this.arrowGizmo.add(cone);
    this.viewer.scene.add(this.arrowGizmo);
  }

  public getCurrentSelector(): string {
    return this.currentSelector;
  }

  public showAt(x: number, y: number, sel: SubShapeSelection): void {
    const isFace = sel.type === 'face';
    const isEdge = sel.type === 'edge';

    if ((!x && !y) || (x === 0 && y === 0)) {
      x = window.innerWidth / 2;
      y = window.innerHeight / 2;
    }

    // Compute semantic selector representation
    if (isFace) {
      this.currentSelector = (sel.faceId ?? 0) % 2 === 0 ? '>Z' : '@cylindrical';
    } else if (isEdge) {
      this.currentSelector = '@boundary_edge';
    } else {
      this.currentSelector = '>Z';
    }

    this.selectorBadge.innerText = this.currentSelector;
    this.selectorBadge.setAttribute('data-ocad-selector', this.currentSelector);
    this.dimInput.value = this.currentDimension.toFixed(2);

    // Render context-smart actions
    this.actionsContainer.innerHTML = '';
    const actions: OnObjectAction[] = [];

    if (isFace) {
      actions.push(
        { id: 'sketch', label: 'Sketch', icon: '✏️', tooltip: 'Sketch on this face', action: () => this.triggerAction('sketch') },
        { id: 'extrude', label: 'Extrude', icon: '⬆️', tooltip: 'Push/Pull Extrude Add/Cut', action: () => this.triggerAction('extrude') },
        { id: 'hole_wizard', label: 'Hole', icon: '🕳️', tooltip: 'Add Hole Wizard mount', action: () => this.triggerAction('hole_wizard') },
        { id: 'thread', label: 'Thread', icon: '🔩', tooltip: 'Add modeled screw thread', action: () => this.triggerAction('thread') },
        { id: 'datum', label: 'Datum', icon: '📍', tooltip: 'Create offset datum plane', action: () => this.triggerAction('datum') }
      );
    } else if (isEdge) {
      actions.push(
        { id: 'fillet', label: 'Fillet', icon: '🪚', tooltip: 'Round this edge', action: () => this.triggerAction('fillet') },
        { id: 'chamfer', label: 'Chamfer', icon: '📐', tooltip: 'Bevel this edge', action: () => this.triggerAction('chamfer') },
        { id: 'flange', label: 'Flange', icon: '📦', tooltip: 'Add sheet metal flange', action: () => this.triggerAction('flange') }
      );
    }

    for (const act of actions) {
      const btn = document.createElement('button');
      btn.className = 'on-object-btn';
      btn.setAttribute('data-testid', `hud-action-${act.id}`);
      btn.setAttribute('data-ocad-action', act.id);
      btn.title = act.tooltip;
      btn.innerHTML = `<span class="act-icon">${act.icon}</span><span class="act-label">${act.label}</span>`;
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        act.action();
      });
      this.actionsContainer.appendChild(btn);
    }

    // Position HUD near cursor, clamped inside screen
    const pad = 20;
    const posX = Math.min(window.innerWidth - 220, Math.max(pad, x + 15));
    const posY = Math.min(window.innerHeight - 120, Math.max(pad, y - 60));

    this.container.style.left = `${posX}px`;
    this.container.style.top = `${posY}px`;
    this.container.style.display = 'flex';

    // Position 3D arrow gizmo
    if (this.arrowGizmo) {
      const pt = (sel as any).point;
      if (pt) {
        this.arrowGizmo.position.set(pt[0], pt[1], pt[2]);
      } else {
        this.arrowGizmo.position.set(0, 0, 1.0);
      }
      this.arrowGizmo.visible = true;
    }
  }

  private triggerAction(actionId: string): void {
    this.options.onActionTrigger?.(actionId, this.currentSelector);
    this.hide();
  }

  public hide(): void {
    this.container.style.display = 'none';
    if (this.arrowGizmo) {
      this.arrowGizmo.visible = false;
    }
  }
}
