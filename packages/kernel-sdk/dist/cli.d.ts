#!/usr/bin/env node
/**
 * @file cli.ts
 * Standalone OpenCAD CLI for headless CI/CD manufacturing pipelines.
 * Usage:
 *   npx opencad build <model.ocad.ts> [--step] [--3mf] [--dxf] [--gcode] [--out-dir ./dist]
 *   npx opencad template <bracket|enclosure|flexure|gyroid> [--out ./model.ocad.ts]
 *   npx opencad info
 */
export declare function printHelp(): void;
export declare function runCli(argv?: string[]): void;
//# sourceMappingURL=cli.d.ts.map