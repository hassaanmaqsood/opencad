export class FpsCounter {
  private frameTimes: number[] = [];
  private maxSamples: number;
  private lastTimestamp: number = 0;
  private currentFps: number = 60.0;
  private currentFrameTimeMs: number = 16.6;

  constructor(samples: number = 60) {
    this.maxSamples = samples;
  }

  public tick(now: number = performance.now()): void {
    if (this.lastTimestamp > 0) {
      const delta = now - this.lastTimestamp;
      this.frameTimes.push(delta);

      if (this.frameTimes.length > this.maxSamples) {
        this.frameTimes.shift();
      }

      const sum = this.frameTimes.reduce((acc, val) => acc + val, 0);
      const avgDelta = sum / this.frameTimes.length;

      this.currentFrameTimeMs = avgDelta;
      this.currentFps = avgDelta > 0 ? 1000 / avgDelta : 60.0;
    }

    this.lastTimestamp = now;
  }

  public getFps(): number {
    return Math.round(this.currentFps * 10) / 10;
  }

  public getFrameTimeMs(): number {
    return Math.round(this.currentFrameTimeMs * 10) / 10;
  }

  public reset(): void {
    this.frameTimes = [];
    this.lastTimestamp = 0;
    this.currentFps = 60.0;
    this.currentFrameTimeMs = 16.6;
  }
}
