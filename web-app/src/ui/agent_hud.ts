/**
 * AgentHud: Floating inspector and terminal for AI-Agent Mode.
 * Exposes WebMCP / JSON-RPC status, live B-Rep validation metrics, and recent agent actions.
 */

export interface AgentLogEntry {
  timestamp: string;
  command: string;
  status: 'ok' | 'error';
  details?: string;
}

export class AgentHud {
  private container: HTMLElement;
  private logListEl: HTMLElement;
  private statusBadgeEl: HTMLElement;
  private bRepStatusEl: HTMLElement;
  private logs: AgentLogEntry[] = [];
  private isVisible: boolean = false;

  constructor() {
    this.container = document.createElement('div');
    this.container.id = 'agent-hud';
    this.container.className = 'agent-hud hud-panel';
    this.container.setAttribute('data-testid', 'agent-hud');
    this.container.style.display = 'none';

    this.container.innerHTML = `
      <div class="agent-hud-header">
        <span class="agent-hud-title">🤖 AI-Agent Bridge (WebMCP)</span>
        <span id="agent-status-badge" class="agent-status-badge" data-testid="agent-status-badge">READY</span>
      </div>
      <div class="agent-hud-endpoint">
        <span class="endpoint-label">RPC Endpoint:</span>
        <code>window.opencadAgent</code>
      </div>
      <div class="agent-hud-brep">
        <span class="brep-label">B-Rep Validation:</span>
        <span id="agent-brep-status" class="brep-value" data-testid="agent-brep-status">Watertight (V-E+F=2)</span>
      </div>
      <div class="agent-hud-log-header">Recent Commands:</div>
      <div id="agent-hud-log-list" class="agent-hud-log-list" data-testid="agent-log-list">
        <div class="agent-log-entry">[READY] Agent bridge listening for JSON-RPC</div>
      </div>
    `;

    document.body.appendChild(this.container);

    this.logListEl = this.container.querySelector('#agent-hud-log-list')!;
    this.statusBadgeEl = this.container.querySelector('#agent-status-badge')!;
    this.bRepStatusEl = this.container.querySelector('#agent-brep-status')!;
  }

  public setVisible(visible: boolean): void {
    this.isVisible = visible;
    this.container.style.display = visible ? 'flex' : 'none';
  }

  public getIsVisible(): boolean {
    return this.isVisible;
  }

  public setStatus(status: 'READY' | 'BUSY' | 'ERROR'): void {
    this.statusBadgeEl.innerText = status;
    this.statusBadgeEl.className = `agent-status-badge status-${status.toLowerCase()}`;
  }

  public setBRepStatus(text: string, isValid: boolean): void {
    this.bRepStatusEl.innerText = text;
    this.bRepStatusEl.className = `brep-value ${isValid ? 'brep-valid' : 'brep-invalid'}`;
  }

  public addLog(command: string, status: 'ok' | 'error' = 'ok', details?: string): void {
    const time = new Date().toLocaleTimeString();
    this.logs.unshift({ timestamp: time, command, status, details });
    if (this.logs.length > 20) this.logs.pop();

    const row = document.createElement('div');
    row.className = `agent-log-entry log-${status}`;
    row.innerText = `[${time}] ${command}${details ? ` -> ${details}` : ''}`;

    this.logListEl.prepend(row);
    while (this.logListEl.children.length > 15) {
      this.logListEl.removeChild(this.logListEl.lastChild!);
    }
  }
}
