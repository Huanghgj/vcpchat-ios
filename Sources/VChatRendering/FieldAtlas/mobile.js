'use strict';
const atlas = mountAtlas(document.getElementById('atlas'), {
    async get(route) {
        const raw = await window.webkit.messageHandlers.atlasRead.postMessage(route);
        try { return JSON.parse(raw); }
        catch { throw new Error('服务器未返回场图数据，请检查 VCP 地址和 WarpedFieldAtlas 插件。'); }
    },
});
const appearance = matchMedia('(prefers-color-scheme: dark)');
const repaint = () => atlas.refreshTheme();
appearance.addEventListener('change', repaint);
window.addEventListener('pagehide', () => {
    appearance.removeEventListener('change', repaint);
    atlas.dispose();
}, { once: true });
