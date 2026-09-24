// Runs in a hidden window: loads one video and returns three 250x250 JPEG screenshots (at 25%, 50% and 75%
// of its length) as data URLs, the whole frame scaled to fit on black. Resolves null when the video cannot be decoded.
const SIZE = 250;
function frame(video) {
  const canvas = document.createElement('canvas'); canvas.width = SIZE; canvas.height = SIZE;
  const context = canvas.getContext('2d'); context.fillStyle = '#000'; context.fillRect(0, 0, SIZE, SIZE);
  const scale = Math.min(SIZE / video.videoWidth, SIZE / video.videoHeight);
  const width = Math.round(video.videoWidth * scale), height = Math.round(video.videoHeight * scale);
  context.drawImage(video, (SIZE - width) / 2, (SIZE - height) / 2, width, height);
  return canvas.toDataURL('image/jpeg', 0.85);
}
window.capture = url => new Promise(resolve => {
  const video = document.createElement('video'); video.muted = true; video.preload = 'auto';
  let finished = false;
  const done = result => {
    if (finished) return; finished = true; clearTimeout(timer);
    video.removeAttribute('src'); video.load(); resolve(result);
  };
  const timer = setTimeout(() => done(null), 60000);
  const seek = time => new Promise((ok, fail) => { video.onseeked = () => ok(); video.onerror = () => fail(new Error('decode')); video.currentTime = time; });
  video.onerror = () => done(null);
  video.onloadeddata = async () => {
    try {
      // Recordings without a duration in their header (some WebM) report Infinity until the end is reached.
      if (!Number.isFinite(video.duration)) await seek(1e7);
      const duration = video.duration;
      if (!Number.isFinite(duration) || duration <= 0 || !video.videoWidth) { done(null); return; }
      const shots = [];
      for (const at of [0.25, 0.5, 0.75]) { await seek(duration * at); shots.push(frame(video)); }
      done(shots);
    } catch { done(null); }
  };
  video.src = url;
});
