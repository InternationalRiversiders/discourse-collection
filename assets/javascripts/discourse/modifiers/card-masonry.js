import { modifier } from "ember-modifier";

// Preserve the keyed DOM (and focused inputs) while CSS Grid fills the shorter
// column. Single-column layouts and browsers without observers keep normal flow.
export function setupCardMasonry(element, selector) {
  if (!window.ResizeObserver || !window.MutationObserver) {
    return;
  }

  let frame;
  let disposed = false;
  let width;
  const cards = new Set();
  const reset = () => {
    element.classList.remove("is-card-masonry");
    cards.forEach((card) => card.style.removeProperty("--card-row-span"));
  };

  const layout = () => {
    frame = undefined;
    if (disposed) {
      return;
    }
    const children = Array.from(element.children);
    const style = getComputedStyle(element);
    const columns = style.gridTemplateColumns.trim().split(/\s+/).length;
    if (
      !element.clientWidth ||
      columns < 2 ||
      !children.length ||
      !children.every((child) => child.matches(selector))
    ) {
      reset();
      return;
    }

    element.classList.add("is-card-masonry");
    const gap = parseFloat(style.columnGap) || 0;
    const spans = children.map((card) =>
      Math.max(1, Math.ceil(card.getBoundingClientRect().height + gap))
    );
    children.forEach((card, index) => {
      const span = String(spans[index]);
      if (card.style.getPropertyValue("--card-row-span") !== span) {
        card.style.setProperty("--card-row-span", span);
      }
    });
  };

  const schedule = () => {
    if (!disposed && frame === undefined) {
      frame = requestAnimationFrame(layout);
    }
  };
  const resize = new ResizeObserver((entries) => {
    for (const entry of entries) {
      if (entry.target !== element || entry.contentRect.width !== width) {
        if (entry.target === element) {
          width = entry.contentRect.width;
        }
        schedule();
      }
    }
  });
  const observeChildren = () => {
    const children = new Set(element.children);
    for (const card of cards) {
      if (!children.has(card)) {
        resize.unobserve(card);
        card.style.removeProperty("--card-row-span");
        cards.delete(card);
      }
    }
    for (const card of children) {
      if (!cards.has(card)) {
        cards.add(card);
        resize.observe(card);
      }
    }
    schedule();
  };
  const mutations = new MutationObserver(observeChildren);
  mutations.observe(element, { childList: true });
  resize.observe(element);
  observeChildren();

  return () => {
    disposed = true;
    cancelAnimationFrame(frame);
    resize.disconnect();
    mutations.disconnect();
    reset();
    cards.clear();
  };
}

export default modifier((element, [selector]) =>
  setupCardMasonry(element, selector)
);
