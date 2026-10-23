import {
  CadSketchConstraint,
  CadSketchConstraintType,
  CadSolveState,
} from '../types/cad';
import { DatumPlane, SketchManager, SketchManagerState } from '../renderer/sketch_manager';
import { SketchToolType } from '../renderer/sketch_tools';

export class SketchHud {
  private manager: SketchManager;
  private container: HTMLElement;
  private toolbarEl: HTMLElement;
  private dimensionPopupEl: HTMLElement;
  private coordReadoutEl: HTMLElement;
  private dofBadgeEl: HTMLElement;
  private statusBadgeEl: HTMLElement;

  private activeEditingConstraint: CadSketchConstraint | null = null;
  private pendingDimensionType: CadSketchConstraintType | null = null;
  private pendingDimensionEntities: number[] = [];

  constructor(manager: SketchManager) {
    this.manager = manager;

    // Create / attach Sketch HUD elements to DOM
    this.container = document.createElement('div');
    this.container.id = 'sketch-hud-root';
    this.container.className = 'sketch-hud-container';
    document.body.appendChild(this.container);

    this.toolbarEl = document.createElement('div');
    this.toolbarEl.id = 'sketch-toolbar';
    this.toolbarEl.className = 'sketch-toolbar hud-panel';
    this.container.appendChild(this.toolbarEl);

    this.dimensionPopupEl = document.createElement('div');
    this.dimensionPopupEl.id = 'dimension-popup';
    this.dimensionPopupEl.className = 'dimension-popup hud-panel';
    this.dimensionPopupEl.style.display = 'none';
    this.container.appendChild(this.dimensionPopupEl);

    this.coordReadoutEl = document.createElement('div');
    this.coordReadoutEl.id = 'sketch-coord-readout';
    this.coordReadoutEl.className = 'sketch-coord-readout hud-panel';
    this.coordReadoutEl.innerHTML = `<span>X: 0.000</span><span>Y: 0.000</span>`;
    this.container.appendChild(this.coordReadoutEl);

    this.dofBadgeEl = document.createElement('div');
    this.statusBadgeEl = document.createElement('div');

    this.renderToolbar();
    this.setupListeners();
  }

  private renderToolbar(): void {
    this.toolbarEl.innerHTML = `
      <div class="sketch-header">
        <span class="sketch-title">✏️ 2D Sketcher</span>
        <button id="btn-exit-sketch" class="btn-sketch-exit" data-testid="btn-exit-sketch">Finish Sketch</button>
      </div>

      <!-- Datum Plane Selector -->
      <div class="sketch-row">
        <label class="sketch-label">Plane:</label>
        <div class="sketch-btn-group">
          <button id="btn-plane-xy" class="btn-toggle active" data-testid="btn-plane-xy">XY</button>
          <button id="btn-plane-xz" class="btn-toggle" data-testid="btn-plane-xz">XZ</button>
          <button id="btn-plane-yz" class="btn-toggle" data-testid="btn-plane-yz">YZ</button>
        </div>
      </div>

      <!-- Drawing Tools -->
      <div class="sketch-row">
        <label class="sketch-label">Tools:</label>
        <div class="sketch-btn-group">
          <button id="tool-select" class="btn-toggle active" title="Select / Drag" data-testid="tool-select">Select</button>
          <button id="tool-line" class="btn-toggle" title="Line" data-testid="tool-line">Line</button>
          <button id="tool-rect" class="btn-toggle" title="Rectangle" data-testid="tool-rect">Rect</button>
          <button id="tool-circle" class="btn-toggle" title="Circle" data-testid="tool-circle">Circle</button>
          <button id="tool-arc" class="btn-toggle" title="Center Arc" data-testid="tool-arc">Arc</button>
        </div>
      </div>

      <!-- Wave 13: Advanced 2D Entities & Modifiers -->
      <div class="sketch-row">
        <label class="sketch-label">Entities:</label>
        <div class="sketch-btn-group">
          <button id="tool-spline" class="btn-toggle" title="NURBS Spline" data-testid="tool-spline">Spline</button>
          <button id="tool-slot" class="btn-toggle" title="Slot / Stadium" data-testid="tool-slot">Slot</button>
          <button id="tool-text" class="btn-toggle" title="Vector Text" data-testid="tool-text">Text</button>
        </div>
      </div>

      <div class="sketch-row">
        <label class="sketch-label">Modify:</label>
        <div class="sketch-btn-group">
          <button id="tool-fillet-2d" class="btn-toggle" title="2D Fillet" data-testid="tool-fillet-2d">Fillet</button>
          <button id="tool-chamfer-2d" class="btn-toggle" title="2D Chamfer" data-testid="tool-chamfer-2d">Chamfer</button>
          <button id="tool-offset" class="btn-toggle" title="Offset Wire" data-testid="tool-offset">Offset</button>
          <button id="tool-trim" class="btn-toggle" title="Trim Curve" data-testid="tool-trim">Trim</button>
        </div>
      </div>

      <div class="sketch-row">
        <label class="sketch-label">Mode:</label>
        <div class="sketch-btn-group">
          <button id="btn-toggle-construction" class="btn-toggle" title="Toggle Construction Geometry (Q)" data-testid="btn-toggle-construction">Const (Q)</button>
          <button id="btn-pick-regions" class="btn-toggle" title="Pick Closed Planar Regions" data-testid="btn-pick-regions">Regions</button>
        </div>
      </div>

      <!-- Constraints -->
      <div class="sketch-section-title">Geometric Constraints</div>
      <div class="sketch-constraints-grid">
        <button id="c-coincident" class="btn-constraint" title="Coincident" data-testid="c-coincident">Coincident</button>
        <button id="c-horizontal" class="btn-constraint" title="Horizontal" data-testid="c-horizontal">Horizontal</button>
        <button id="c-vertical" class="btn-constraint" title="Vertical" data-testid="c-vertical">Vertical</button>
        <button id="c-parallel" class="btn-constraint" title="Parallel" data-testid="c-parallel">Parallel</button>
        <button id="c-perpendicular" class="btn-constraint" title="Perpendicular" data-testid="c-perpendicular">Perpend.</button>
        <button id="c-tangent" class="btn-constraint" title="Tangent" data-testid="c-tangent">Tangent</button>
        <button id="c-equal" class="btn-constraint" title="Equal Length / Radius" data-testid="c-equal">Equal</button>
        <button id="c-symmetric" class="btn-constraint" title="Symmetric" data-testid="c-symmetric">Symmetric</button>
        <button id="c-distance" class="btn-constraint btn-dim" title="Distance / Length" data-testid="c-distance">Distance</button>
        <button id="c-angle" class="btn-constraint btn-dim" title="Angle" data-testid="c-angle">Angle</button>
        <button id="c-radius" class="btn-constraint btn-dim" title="Radius" data-testid="c-radius">Radius</button>
      </div>

      <!-- Diagnostic DOF & Convergence Badge -->
      <div class="sketch-dof-container">
        <div class="dof-row">
          <span>Degrees of Freedom:</span>
          <span id="sketch-dof-val" class="dof-badge" data-testid="sketch-dof-val">0 DOF</span>
        </div>
        <div class="status-row">
          <span>Status:</span>
          <span id="sketch-status-val" class="status-badge" data-testid="sketch-status-val">Under-Constrained</span>
        </div>
      </div>
    `;

    this.dimensionPopupEl.innerHTML = `
      <div class="dim-title" id="dim-title">Edit Dimension</div>
      <div class="dim-input-row">
        <input type="number" id="dim-value-input" class="dim-input" step="0.1" value="2.0" data-testid="dim-value-input" />
        <span class="dim-unit" id="dim-unit">mm</span>
      </div>
      <div class="dim-btn-row">
        <button id="dim-btn-ok" class="btn-dim-ok" data-testid="dim-btn-ok">Apply</button>
        <button id="dim-btn-cancel" class="btn-dim-cancel">Cancel</button>
      </div>
    `;

    this.dofBadgeEl = document.getElementById('sketch-dof-val')!;
    this.statusBadgeEl = document.getElementById('sketch-status-val')!;
  }

  private setupListeners(): void {
    // Finish / Exit sketch
    document.getElementById('btn-exit-sketch')?.addEventListener('click', () => {
      this.manager.exitSketchMode();
    });

    // Datum planes
    const planeXY = document.getElementById('btn-plane-xy');
    const planeXZ = document.getElementById('btn-plane-xz');
    const planeYZ = document.getElementById('btn-plane-yz');

    const selectPlane = (plane: DatumPlane) => {
      planeXY?.classList.toggle('active', plane === 'XY');
      planeXZ?.classList.toggle('active', plane === 'XZ');
      planeYZ?.classList.toggle('active', plane === 'YZ');
      this.manager.enterSketchMode(plane);
    };

    planeXY?.addEventListener('click', () => selectPlane('XY'));
    planeXZ?.addEventListener('click', () => selectPlane('XZ'));
    planeYZ?.addEventListener('click', () => selectPlane('YZ'));

    // Tools
    const tools: { id: string; type: SketchToolType }[] = [
      { id: 'tool-select', type: 'select' },
      { id: 'tool-line', type: 'line' },
      { id: 'tool-rect', type: 'rectangle' },
      { id: 'tool-circle', type: 'circle' },
      { id: 'tool-arc', type: 'arc' },
      { id: 'tool-spline', type: 'spline' },
      { id: 'tool-slot', type: 'slot' },
      { id: 'tool-text', type: 'text' },
      { id: 'tool-fillet-2d', type: 'fillet' },
      { id: 'tool-chamfer-2d', type: 'chamfer' },
      { id: 'tool-offset', type: 'offset' },
      { id: 'tool-trim', type: 'trim' },
    ];

    for (const t of tools) {
      document.getElementById(t.id)?.addEventListener('click', () => {
        tools.forEach((item) => document.getElementById(item.id)?.classList.remove('active'));
        document.getElementById(t.id)?.classList.add('active');
        this.manager.setTool(t.type);
      });
    }

    // Construction Mode Toggle (Button & 'Q' shortcut)
    const constBtn = document.getElementById('btn-toggle-construction');
    const toggleConst = () => {
      const active = this.manager.toggleConstruction();
      constBtn?.classList.toggle('active', active);
    };
    constBtn?.addEventListener('click', toggleConst);

    window.addEventListener('keydown', (e: KeyboardEvent) => {
      if (this.manager.inSketchMode && (e.key === 'q' || e.key === 'Q')) {
        const target = e.target as HTMLElement;
        if (target.tagName !== 'INPUT' && target.tagName !== 'TEXTAREA') {
          e.preventDefault();
          toggleConst();
        }
      }
    });

    // Planar Regions Picking
    const regionsBtn = document.getElementById('btn-pick-regions');
    regionsBtn?.addEventListener('click', () => {
      regionsBtn.classList.toggle('active');
    });

    // Constraint buttons
    document.getElementById('c-horizontal')?.addEventListener('click', () => {
      const lineIds = Array.from(this.manager.selectedLineIds);
      const ptIds = Array.from(this.manager.selectedPointIds);
      if (lineIds.length > 0) {
        this.manager.addConstraint(CadSketchConstraintType.HORIZONTAL, lineIds[0]);
      } else if (ptIds.length >= 2) {
        this.manager.addConstraint(CadSketchConstraintType.HORIZONTAL, ptIds[0], ptIds[1]);
      }
    });

    document.getElementById('c-vertical')?.addEventListener('click', () => {
      const lineIds = Array.from(this.manager.selectedLineIds);
      const ptIds = Array.from(this.manager.selectedPointIds);
      if (lineIds.length > 0) {
        this.manager.addConstraint(CadSketchConstraintType.VERTICAL, lineIds[0]);
      } else if (ptIds.length >= 2) {
        this.manager.addConstraint(CadSketchConstraintType.VERTICAL, ptIds[0], ptIds[1]);
      }
    });

    document.getElementById('c-coincident')?.addEventListener('click', () => {
      const ptIds = Array.from(this.manager.selectedPointIds);
      if (ptIds.length >= 2) {
        this.manager.addConstraint(CadSketchConstraintType.COINCIDENT, ptIds[0], ptIds[1]);
      }
    });

    document.getElementById('c-parallel')?.addEventListener('click', () => {
      const lineIds = Array.from(this.manager.selectedLineIds);
      if (lineIds.length >= 2) {
        this.manager.addConstraint(CadSketchConstraintType.PARALLEL, lineIds[0], lineIds[1]);
      }
    });

    document.getElementById('c-perpendicular')?.addEventListener('click', () => {
      const lineIds = Array.from(this.manager.selectedLineIds);
      if (lineIds.length >= 2) {
        this.manager.addConstraint(CadSketchConstraintType.PERPENDICULAR, lineIds[0], lineIds[1]);
      }
    });

    document.getElementById('c-equal')?.addEventListener('click', () => {
      const lineIds = Array.from(this.manager.selectedLineIds);
      if (lineIds.length >= 2) {
        this.manager.addConstraint(CadSketchConstraintType.EQUAL, lineIds[0], lineIds[1]);
      }
    });

    document.getElementById('c-distance')?.addEventListener('click', (e) => {
      const lineIds = Array.from(this.manager.selectedLineIds);
      const ptIds = Array.from(this.manager.selectedPointIds);

      if (lineIds.length > 0) {
        this.openDimensionPopup(
          CadSketchConstraintType.DISTANCE,
          [lineIds[0]],
          2.0,
          'Distance / Length',
          'mm',
          (e as MouseEvent).clientX,
          (e as MouseEvent).clientY
        );
      } else if (ptIds.length >= 2) {
        this.openDimensionPopup(
          CadSketchConstraintType.DISTANCE,
          [ptIds[0], ptIds[1]],
          2.0,
          'Distance Between Points',
          'mm',
          (e as MouseEvent).clientX,
          (e as MouseEvent).clientY
        );
      }
    });

    document.getElementById('c-radius')?.addEventListener('click', (e) => {
      const circleIds = Array.from(this.manager.selectedCircleIds);
      const arcIds = Array.from(this.manager.selectedArcIds);
      const targetId = circleIds[0] ?? arcIds[0];
      if (targetId !== undefined) {
        this.openDimensionPopup(
          CadSketchConstraintType.RADIUS,
          [targetId],
          1.5,
          'Radius',
          'mm',
          (e as MouseEvent).clientX,
          (e as MouseEvent).clientY
        );
      }
    });

    document.getElementById('c-angle')?.addEventListener('click', (e) => {
      const lineIds = Array.from(this.manager.selectedLineIds);
      if (lineIds.length >= 2) {
        this.openDimensionPopup(
          CadSketchConstraintType.ANGLE,
          [lineIds[0], lineIds[1]],
          90.0,
          'Angle Between Lines',
          'deg',
          (e as MouseEvent).clientX,
          (e as MouseEvent).clientY
        );
      }
    });

    // Dimension popup OK & Cancel
    document.getElementById('dim-btn-ok')?.addEventListener('click', () => {
      this.applyDimensionInput();
    });

    document.getElementById('dim-value-input')?.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        this.applyDimensionInput();
      } else if (e.key === 'Escape') {
        this.closeDimensionPopup();
      }
    });

    document.getElementById('dim-btn-cancel')?.addEventListener('click', () => {
      this.closeDimensionPopup();
    });

    // Coordinate & state listeners from SketchManager
    this.manager.onCoordinateChange = (u, v) => {
      this.coordReadoutEl.innerHTML = `<span>X: ${u.toFixed(3)}</span><span>Y: ${v.toFixed(3)}</span>`;
    };

    this.manager.onStateChange = (state) => {
      this.updateFromState(state);
    };

    this.manager.onRequestDimensionEdit = (constraint, clientX, clientY) => {
      this.activeEditingConstraint = constraint;
      const isAngle = constraint.type === CadSketchConstraintType.ANGLE;
      const val = isAngle
        ? ((constraint.parameter_value ?? 0) * 180) / Math.PI
        : constraint.parameter_value ?? 1.0;
      this.openDimensionPopup(
        constraint.type,
        [constraint.entity1_id],
        val,
        'Edit Dimension',
        isAngle ? 'deg' : 'mm',
        clientX,
        clientY
      );
    };
  }

  private openDimensionPopup(
    type: CadSketchConstraintType,
    entities: number[],
    initialVal: number,
    title: string,
    unit: string,
    clientX: number,
    clientY: number
  ): void {
    this.pendingDimensionType = type;
    this.pendingDimensionEntities = entities;

    const titleEl = document.getElementById('dim-title');
    const inputEl = document.getElementById('dim-value-input') as HTMLInputElement;
    const unitEl = document.getElementById('dim-unit');

    if (titleEl) titleEl.textContent = title;
    if (unitEl) unitEl.textContent = unit;
    if (inputEl) {
      inputEl.value = initialVal.toFixed(2);
      inputEl.focus();
      inputEl.select();
    }

    this.dimensionPopupEl.style.left = `${Math.min(window.innerWidth - 220, Math.max(20, clientX - 80))}px`;
    this.dimensionPopupEl.style.top = `${Math.min(window.innerHeight - 150, Math.max(20, clientY - 60))}px`;
    this.dimensionPopupEl.style.display = 'block';
  }

  private closeDimensionPopup(): void {
    this.dimensionPopupEl.style.display = 'none';
    this.activeEditingConstraint = null;
    this.pendingDimensionType = null;
    this.pendingDimensionEntities = [];
  }

  private applyDimensionInput(): void {
    const inputEl = document.getElementById('dim-value-input') as HTMLInputElement;
    const val = parseFloat(inputEl.value);
    if (isNaN(val)) return;

    if (this.activeEditingConstraint) {
      const isAngle = this.activeEditingConstraint.type === CadSketchConstraintType.ANGLE;
      const paramVal = isAngle ? (val * Math.PI) / 180 : val;
      this.manager.updateConstraintValue(this.activeEditingConstraint.id, paramVal);
    } else if (this.pendingDimensionType !== null) {
      const isAngle = this.pendingDimensionType === CadSketchConstraintType.ANGLE;
      const paramVal = isAngle ? (val * Math.PI) / 180 : val;
      this.manager.addConstraint(
        this.pendingDimensionType,
        this.pendingDimensionEntities[0],
        this.pendingDimensionEntities[1],
        undefined,
        undefined,
        paramVal
      );
    }

    this.closeDimensionPopup();
  }

  public updateFromState(state: SketchManagerState): void {
    this.container.style.display = state.inSketchMode ? 'block' : 'none';

    // Update DOF
    this.dofBadgeEl.textContent = `${state.dof} DOF`;

    // Update Status & Color
    let statusText = 'Under-Constrained';
    let statusClass = 'status-under';

    if (state.solveState === CadSolveState.CONFLICTING || state.solveState === CadSolveState.OVER_CONSTRAINED) {
      statusText = 'Over-Constrained / Conflict';
      statusClass = 'status-conflict';
    } else if (state.solveState === CadSolveState.SOLVED || state.dof === 0) {
      statusText = 'Fully Constrained (0 DOF)';
      statusClass = 'status-solved';
    }

    this.statusBadgeEl.textContent = statusText;
    this.statusBadgeEl.className = `status-badge ${statusClass}`;
  }
}
