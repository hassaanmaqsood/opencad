/**
 * RadialPieMenu: 'S'-key radial / pie menu for instant CAD action triggers.
 */

export interface RadialMenuItem {
  id: string;
  label: string;
  shortcut: string;
  icon: string;
  action: () => void;
}

export class RadialPieMenu {
  private container: HTMLElement;
  private isOpen: boolean = false;
  private items: RadialMenuItem[];

  constructor(items: RadialMenuItem[]) {
    this.items = items;
    this.container = document.createElement('div');
    this.container.id = 'radial-pie-menu';
    this.container.className = 'radial-pie-menu';
    this.container.setAttribute('data-testid', 'radial-pie-menu');
    this.container.style.display = 'none';
    document.body.appendChild(this.container);

    this.render();
    this.setupListeners();
  }

  private render(): void {
    this.container.innerHTML = '';
    const center = document.createElement('div');
    center.className = 'radial-center-badge';
    center.innerText = '⚙️';
    this.container.appendChild(center);

    const radius = 90; // px
    const count = this.items.length;

    for (let i = 0; i < count; i++) {
      const item = this.items[i];
      const angle = (i / count) * 2 * Math.PI - Math.PI / 2;
      const x = Math.round(Math.cos(angle) * radius);
      const y = Math.round(Math.sin(angle) * radius);

      const btn = document.createElement('button');
      btn.className = 'radial-item-btn';
      btn.setAttribute('data-testid', `radial-${item.id}`);
      btn.style.transform = `translate(${x}px, ${y}px)`;
      btn.innerHTML = `
        <span class="radial-icon">${item.icon}</span>
        <span class="radial-label">${item.label}</span>
        <span class="radial-key">${item.shortcut}</span>
      `;
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        this.close();
        item.action();
      });
      this.container.appendChild(btn);
    }
  }

  private setupListeners(): void {
    window.addEventListener('keydown', (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        if (this.isOpen) {
          this.close();
        }
        return;
      }

      const target = e.target as HTMLElement;
      if (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.closest('.monaco-editor')) {
        return;
      }

      if ((e.key === 's' || e.key === 'S') && !e.ctrlKey && !e.metaKey && !e.altKey) {
        e.preventDefault();
        if (this.isOpen) {
          this.close();
        } else {
          // Center around last known mouse position or screen center
          const x = (window as any).__lastMouseX ?? window.innerWidth / 2;
          const y = (window as any).__lastMouseY ?? window.innerHeight / 2;
          this.open(x, y);
        }
      }
    });

    window.addEventListener('mousemove', (e: MouseEvent) => {
      (window as any).__lastMouseX = e.clientX;
      (window as any).__lastMouseY = e.clientY;
    });

    window.addEventListener('pointerdown', (e: MouseEvent) => {
      if (this.isOpen && !this.container.contains(e.target as Node)) {
        this.close();
      }
    });
  }

  public open(x: number, y: number): void {
    this.container.style.left = `${x}px`;
    this.container.style.top = `${y}px`;
    this.container.style.display = 'flex';
    this.isOpen = true;
  }

  public close(): void {
    this.container.style.display = 'none';
    this.isOpen = false;
  }

  public toggle(x?: number, y?: number): void {
    if (this.isOpen) {
      this.close();
    } else {
      this.open(x ?? window.innerWidth / 2, y ?? window.innerHeight / 2);
    }
  }
}
