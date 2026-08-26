import { MoonlightCatalogItem } from '../services/MoonlightUiPolicy';

/** Isolated lazy source; it never touches RemoteHost or another protocol list. */
export class MoonlightCatalogDataSource implements IDataSource {
  private items: MoonlightCatalogItem[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number { return this.items.length; }

  getData(index: number): MoonlightCatalogItem { return this.items[index]; }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) { this.listeners.push(listener); }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) { this.listeners.splice(index, 1); }
  }

  replaceAll(items: MoonlightCatalogItem[]): void {
    this.items = items.slice();
    this.listeners.forEach((listener: DataChangeListener): void => {
      listener.onDataReloaded();
    });
  }
}
