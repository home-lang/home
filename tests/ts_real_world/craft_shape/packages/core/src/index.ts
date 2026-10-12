import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { EventEmitter } from 'node:events'

export interface WindowOptions {
  title: string
  width?: number
  height?: number
  resizable?: boolean
}

export type Listener = (payload: { name: string, value: number }) => void

export class Bridge extends EventEmitter {
  private readonly pending: Map<string, Listener> = new Map()

  register(name: string, listener: Listener): () => void {
    this.pending.set(name, listener)
    return (): void => {
      this.pending.delete(name)
    }
  }

  dispatch(name: string, value: number): boolean {
    const listener = this.pending.get(name)
    if (!listener)
      return false
    listener({ name, value })
    this.emit('dispatch', name)
    return true
  }
}

export function readConfig(root: string): Record<string, unknown> {
  const text = readFileSync(join(root, 'craft.json'), 'utf8')
  return JSON.parse(text) as Record<string, unknown>
}

export function measure(element: HTMLElement): { width: number, height: number } {
  const rect = element.getBoundingClientRect()
  return { width: rect.width, height: rect.height }
}

export function observe(element: Element, onResize: (width: number) => void): ResizeObserver {
  const observer = new ResizeObserver((entries) => {
    for (const entry of entries)
      onResize(entry.contentRect.width)
  })
  observer.observe(element)
  return observer
}

export async function runtimeVersion(): Promise<string> {
  const file = Bun.file(join(import.meta.dir, 'package.json'))
  const manifest = await file.json() as { version?: string }
  return manifest.version ?? Bun.version
}

export const defaults: WindowOptions = { title: 'Craft', width: 800, height: 600 }
