// A computer can't install an iPhone app, so there the beta buttons show a code to scan.
// With no script, or on a phone, they're plain links to TestFlight.
if (matchMedia("(hover: hover) and (pointer: fine)").matches) {
  const link = "https://testflight.apple.com/join/M2ZrEUV1";
  let box;
  const open = () => {
    if (!box) {
      box = document.createElement("dialog");
      box.className = "qr";
      box.setAttribute("aria-labelledby", "qrHead");
      box.innerHTML = `<button type="button" class="x" aria-label="Close"><svg viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true"><path d="M2 2l10 10M12 2 2 12"/></svg></button><svg class="code" viewBox="0 0 29 29" role="img" aria-label="QR code for the TestFlight beta"><path d="M0 0h7v1h-7zM9 0h1v1h-1zM12 0h9v1h-9zM22 0h7v1h-7zM0 1h1v1h-1zM6 1h1v1h-1zM9 1h3v1h-3zM13 1h1v1h-1zM15 1h1v1h-1zM22 1h1v1h-1zM28 1h1v1h-1zM0 2h1v1h-1zM2 2h3v1h-3zM6 2h1v1h-1zM8 2h1v1h-1zM12 2h1v1h-1zM18 2h1v1h-1zM22 2h1v1h-1zM24 2h3v1h-3zM28 2h1v1h-1zM0 3h1v1h-1zM2 3h3v1h-3zM6 3h1v1h-1zM8 3h1v1h-1zM11 3h1v1h-1zM13 3h5v1h-5zM20 3h1v1h-1zM22 3h1v1h-1zM24 3h3v1h-3zM28 3h1v1h-1zM0 4h1v1h-1zM2 4h3v1h-3zM6 4h1v1h-1zM8 4h1v1h-1zM14 4h1v1h-1zM18 4h3v1h-3zM22 4h1v1h-1zM24 4h3v1h-3zM28 4h1v1h-1zM0 5h1v1h-1zM6 5h1v1h-1zM8 5h6v1h-6zM15 5h2v1h-2zM22 5h1v1h-1zM28 5h1v1h-1zM0 6h7v1h-7zM8 6h1v1h-1zM10 6h1v1h-1zM12 6h1v1h-1zM14 6h1v1h-1zM16 6h1v1h-1zM18 6h1v1h-1zM20 6h1v1h-1zM22 6h7v1h-7zM8 7h2v1h-2zM11 7h2v1h-2zM15 7h2v1h-2zM0 8h1v1h-1zM2 8h5v1h-5zM11 8h1v1h-1zM14 8h1v1h-1zM17 8h2v1h-2zM20 8h1v1h-1zM22 8h5v1h-5zM0 9h2v1h-2zM3 9h3v1h-3zM7 9h1v1h-1zM15 9h10v1h-10zM28 9h1v1h-1zM1 10h1v1h-1zM4 10h3v1h-3zM9 10h1v1h-1zM12 10h1v1h-1zM14 10h4v1h-4zM20 10h1v1h-1zM24 10h1v1h-1zM1 11h2v1h-2zM4 11h2v1h-2zM7 11h1v1h-1zM12 11h1v1h-1zM14 11h1v1h-1zM16 11h1v1h-1zM18 11h1v1h-1zM21 11h5v1h-5zM27 11h1v1h-1zM0 12h3v1h-3zM5 12h4v1h-4zM12 12h1v1h-1zM14 12h1v1h-1zM17 12h1v1h-1zM23 12h1v1h-1zM25 12h2v1h-2zM2 13h1v1h-1zM4 13h2v1h-2zM7 13h1v1h-1zM9 13h3v1h-3zM14 13h1v1h-1zM18 13h7v1h-7zM28 13h1v1h-1zM0 14h1v1h-1zM5 14h2v1h-2zM10 14h2v1h-2zM14 14h2v1h-2zM17 14h2v1h-2zM22 14h2v1h-2zM25 14h2v1h-2zM0 15h2v1h-2zM3 15h1v1h-1zM7 15h2v1h-2zM14 15h1v1h-1zM16 15h1v1h-1zM19 15h3v1h-3zM24 15h1v1h-1zM27 15h1v1h-1zM1 16h2v1h-2zM4 16h4v1h-4zM12 16h1v1h-1zM14 16h1v1h-1zM17 16h1v1h-1zM19 16h1v1h-1zM23 16h1v1h-1zM25 16h2v1h-2zM0 17h1v1h-1zM3 17h3v1h-3zM11 17h2v1h-2zM14 17h1v1h-1zM16 17h4v1h-4zM21 17h4v1h-4zM26 17h1v1h-1zM28 17h1v1h-1zM0 18h1v1h-1zM2 18h2v1h-2zM6 18h2v1h-2zM10 18h8v1h-8zM21 18h4v1h-4zM26 18h1v1h-1zM0 19h1v1h-1zM2 19h2v1h-2zM5 19h1v1h-1zM7 19h1v1h-1zM9 19h1v1h-1zM15 19h1v1h-1zM20 19h1v1h-1zM23 19h2v1h-2zM27 19h1v1h-1zM0 20h1v1h-1zM4 20h1v1h-1zM6 20h3v1h-3zM10 20h2v1h-2zM13 20h1v1h-1zM17 20h1v1h-1zM20 20h5v1h-5zM26 20h3v1h-3zM8 21h5v1h-5zM14 21h1v1h-1zM16 21h5v1h-5zM24 21h5v1h-5zM0 22h7v1h-7zM9 22h1v1h-1zM12 22h1v1h-1zM15 22h2v1h-2zM19 22h2v1h-2zM22 22h1v1h-1zM24 22h3v1h-3zM0 23h1v1h-1zM6 23h1v1h-1zM8 23h1v1h-1zM10 23h2v1h-2zM14 23h1v1h-1zM16 23h1v1h-1zM19 23h2v1h-2zM24 23h1v1h-1zM27 23h2v1h-2zM0 24h1v1h-1zM2 24h3v1h-3zM6 24h1v1h-1zM8 24h1v1h-1zM10 24h1v1h-1zM12 24h1v1h-1zM17 24h2v1h-2zM20 24h5v1h-5zM26 24h3v1h-3zM0 25h1v1h-1zM2 25h3v1h-3zM6 25h1v1h-1zM8 25h2v1h-2zM11 25h3v1h-3zM16 25h3v1h-3zM25 25h4v1h-4zM0 26h1v1h-1zM2 26h3v1h-3zM6 26h1v1h-1zM8 26h2v1h-2zM14 26h2v1h-2zM17 26h1v1h-1zM20 26h8v1h-8zM0 27h1v1h-1zM6 27h1v1h-1zM9 27h1v1h-1zM20 27h1v1h-1zM24 27h2v1h-2zM27 27h1v1h-1zM0 28h7v1h-7zM8 28h4v1h-4zM17 28h1v1h-1zM19 28h1v1h-1zM22 28h5v1h-5z"/></svg><h2 id="qrHead">Scan it with your iPhone.</h2><p>Free and open source. iPhone, iOS 27 or later.</p><a href="${link}">Open the link here instead</a>`;
      box.querySelector(".x").addEventListener("click", () => box.close());
      box.addEventListener("click", e => { if (e.target === box && !e.target.closest("button,a,svg,h2,p")) { const r = box.getBoundingClientRect(); if (e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom) box.close(); } });
      document.body.append(box);
    }
    box.showModal();
  };
  document.addEventListener("click", e => {
    const a = e.target.closest?.('a.go[href^="https://testflight"]');
    if (!a || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    e.preventDefault();
    open();
  });
}
