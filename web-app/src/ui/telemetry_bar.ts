/**
 * @file telemetry_bar.ts
 * Wave 14: Bottom-Right Live Command Telemetry Bar.
 * Echoes every GUI click and operation as its equivalent one-line Code-CAD command,
 * effortlessly teaching Makers and Engineers how the code works with 1-click clipboard copy.
 */

export class TelemetryBar {
  private container: HTMLElement;
  private codeEl: HTMLElement;
  private copyBtn: HTMLButtonElement;
  private currentCommand: string = 'part.faces(">Z").holeWizard("M6", "counterbore");';

  constructor(containerId = 'telemetry-bar') {
    let el = document.getElementById(containerId);
    if (!el) {
      el = document.createElement('div');
      el.id = containerId;
      document.body.appendChild(el);
    }
    this.container = el;
    this.container.className = 'telemetry-bar hud-panel';
    this.container.setAttribute('data-testid', 'telemetry-bar');

    this.container.innerHTML = `
      <span class="telemetry-icon">⚡</span>
      <span class="telemetry-code" id="telemetry-code-text" data-testid="telemetry-code">${this.currentCommand}</span>
      <button class="telemetry-copy-btn" id="telemetry-copy-btn" data-testid="telemetry-copy-btn" title="Copy Code-CAD snippet">📋 Copy</button>
    `;

    this.codeEl = this.container.querySelector('#telemetry-code-text')!;
    this.copyBtn = this.container.querySelector('#telemetry-copy-btn')!;

    this.setupListeners();
  }

  private setupListeners(): void {
    const doCopy = () => {
      navigator.clipboard?.writeText(this.currentCommand);
      const prev = this.copyBtn.innerText;
      this.copyBtn.innerText = 'Copied!';
      setTimeout(() => {
        this.copyBtn.innerText = prev;
      }, 1000);
    };

    this.copyBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      doCopy();
    });

    this.container.addEventListener('click', () => {
      doCopy();
    });
  }

  public setCommand(commandStr: string): void {
    this.currentCommand = commandStr;
    if (this.codeEl) {
      this.codeEl.innerText = commandStr;
    }
    this.container.setAttribute('data-ocad-telemetry', commandStr);
  }

  public setCode(code: string): void {
    this.setCommand(code);
  }

  public getCommand(): string {
    return this.currentCommand;
  }
}
