/*
 * trail.js
 *
 * Renders the decorative meandering SVG trail that runs down the home page,
 * and plants the decorative "here" ring on it at a fixed vertical position.
 *
 * ============================================================================
 * ARCHITECTURE
 * ============================================================================
 *
 *   buildTrail()   generates `pts` from the masthead bottom to the document
 *                  bottom, then paints them as SVG paths + decorations
 *                  (trace, dashed main, head, strays, start marker, end
 *                  cross) inside #trailSvg.
 *   placeHere()    one-shot: computes the trail's x at the ring's fixed
 *                  y (top: 22vh) and sets #here's `left`. The ring does
 *                  NOT track scroll by design. It's a decorative anchor.
 *
 * Both run on load and on resize (debounced 120ms). Neither runs on scroll.
 *
 * ============================================================================
 * COORDINATE SYSTEM (important for modifications)
 * ============================================================================
 *
 * The trail SVG lives inside .trail, which lives inside .page (the centered
 * container with max-width: 96rem). Because .page is the nearest positioned
 * ancestor, the SVG's y=0 maps visually to the TOP OF .page, not the top of
 * the document. The sticky ticker above .page creates a vertical gap.
 *
 * Any document-space input (scrollY, getBoundingClientRect) has to be
 * converted before use as an SVG y value:
 *
 *     svg_y = document_y - pageOffset
 *
 * This is applied in buildTrail() (for trailStartY) and placeHere() (for
 * the ring's y).
 *
 * ============================================================================
 * THINGS YOU MIGHT WANT TO TWEAK
 * ============================================================================
 *
 *   Where the trail starts horizontally  driftBounds(): 0.84 = 84% of width.
 *   How far it drifts left after midpoint  driftBounds(): 0.66 is the pull.
 *   When drift begins                    driftBounds(): the 0.5 threshold.
 *   Wiggle amplitude / turbulence        generateTrail(): base 22, chaos
 *                                        curve pow 1.7, layered sines,
 *                                        thresholds 0.45 and 0.78.
 *   Number of trail segments             generateTrail(): segs = 140.
 *   Marker sizes, dash patterns, colors  inline in buildTrail().
 *   Stray satellites                     strayCount and drift math in
 *                                        buildTrail().
 *   Ring vertical position               CSS .here { top: 22vh }. If you
 *                                        change it, change the 0.22
 *                                        multiplier in placeHere() too so
 *                                        it still lands on the trail.
 *   Rebuild debounce                     scheduleRebuild(): 120ms.
 */

(function() {
    "use strict";

    const SVG_NS = "http://www.w3.org/2000/svg";
    const trailSvg = document.getElementById("trailSvg");
    const trailWrap = document.querySelector(".trail");
    const here = document.getElementById("here");

    // Populated by buildTrail(), read by the strays loop and placeHere().
    let pts = [];
    // SVG-space y where the trail begins (just under the masthead border).
    let trailStartY = 0;
    // Document-y of .page's top edge; subtract from document-y to get SVG-y.
    let pageOffset = 0;

    // ========================================================================
    // HELPERS
    // ========================================================================

    /*
     * driftBounds(t, width)
     *
     * Returns the trail's horizontal center + bounds at parameter t (0..1
     * along the path). For t <= 0.5 the trail hugs the right side (cx = 84%
     * of width). After the midpoint, cx smoothsteps leftward to ~18% of
     * width by t = 1, pulling the clamping bounds with it so the trail
     * can actually reach that far left.
     *
     * The smoothstep formula `u*u*(3 - 2*u)` gives an S-curve (slow in,
     * fast middle, slow out) so the bend looks natural rather than linear.
     */

    function driftBounds(t, width) {
        const driftT = Math.max(0, (t - 0.5) / 0.5);
        const eased = driftT * driftT * (3 - 2 * driftT);
        return {
            cx: width * (0.84 - eased * 0.66),
            minX: width * (0.64 - eased * 0.6),
            maxX: width * (1 - eased * 0.66) - 36,
        };
    }

    /*
     * generateTrail(width, height, startY)
     *
     * Builds an array of {x, y} points from startY down to height, one per
     * segment (segs + 1 points total). Each point's x is the drift center
     * (driftBounds(t).cx) plus layered sine wiggles, clamped to the drift
     * bounds so the trail can't escape its envelope.
     *
     * `chaos = t^1.7` is a curve that starts flat and accelerates. It drives
     * amplitude growth and gates the higher-frequency layers:
     *   - Base: 3 layered sines always contribute.
     *   - If chaos > 0.45: add a much higher-frequency wiggle (turbulence).
     *   - If chaos > 0.78: add an even larger low-frequency wobble.
     *
     * Net effect: smooth near the top, progressively more chaotic toward
     * the bottom of the page.
     */
    function generateTrail(width, height, startY) {
        const segs = 140;
        const result = [];
        const span = height - startY;
        for (let i = 0; i <= segs; i++) {
            const t = i / segs;
            const y = startY + t * span;
            const chaos = Math.pow(t, 1.7);
            const amp = 22 + chaos * (width * 0.13);
            const { cx, minX, maxX } = driftBounds(t, width);
            let offset =
                Math.sin(t * Math.PI * 3.4) * amp * 0.75 +
                Math.sin(t * Math.PI * 8.2 + 1.3) * amp * 0.35 +
                Math.sin(t * Math.PI * 17.1 + 2.4) * amp * (0.15 + chaos * 0.4);
            if (chaos > 0.45) {
                offset += Math.sin(t * Math.PI * 42 + 3.1) * (chaos - 0.45) * 85;
            }
            if (chaos > 0.78) {
                offset += Math.sin(t * Math.PI * 6) * 110 * (chaos - 0.78) * 3;
            }
            let x = cx + offset;
            x = Math.max(minX, Math.min(maxX, x));
            result.push({ x, y });
        }
        return result;
    }

    /*
     * pathD(points)
     *
     * Converts a point array to an SVG path `d` string. Uses cubic beziers
     * with control points at the midpoint y of each segment, which softens
     * the corners between points so the trail reads as a smooth curve
     * rather than a polyline.
     */
    function pathD(points) {
        if (!points.length) return "";
        let d = "M" + points[0].x.toFixed(2) + "," + points[0].y.toFixed(2);
        for (let i = 1; i < points.length; i++) {
            const p0 = points[i - 1];
            const p1 = points[i];
            const cy = (p0.y + p1.y) / 2;
            d += " C" + p0.x.toFixed(2) + "," + cy.toFixed(2) + " " + p1.x.toFixed(2) + "," + cy.toFixed(2) + " " + p1.x.toFixed(2) + "," + p1.y.toFixed(2);
        }
        return d;
    }

    /*
     * xAtY(points, targetY)
     *
     * Finds the x value of the trail at a given y. Linear interpolation
     * between adjacent points. Clamps to the first/last x if targetY is
     * outside the trail's y range (useful near the top of the page where
     * the ring sits above the trail start).
     */
    function xAtY(points, targetY) {
        if (!points.length) return 0;
        if (targetY <= points[0].y) return points[0].x;
        for (let i = 0; i < points.length - 1; i++) {
            if (points[i].y <= targetY && targetY <= points[i + 1].y) {
                const span = points[i + 1].y - points[i].y;
                const t = span > 0 ? (targetY - points[i].y) / span : 0;
                return points[i].x + t * (points[i + 1].x - points[i].x);
            }
        }
        return points[points.length - 1].x;
    }

    // ========================================================================
    // MAIN RENDERING
    // ========================================================================

    /*
     * buildTrail()
     *
     * The orchestrator. Measures the page, computes the SVG coordinate
     * offsets, generates `pts`, clears the SVG, and paints in z-order
     * (lowest first):
     *
     *   1. trace   wide, faint continuous path ("halo" under the dashes)
     *   2. main    thin dashed path (the actual visible trail)
     *   3. head    short solid segment at the start so the anchor reads
     *   4. strays  7 satellite circles with dashed connector lines
     *   5. start   dark green dashed ring with a filled center dot
     *   6. end     red X cross at the bottom of the trail
     */
    function buildTrail() {
        const w = document.documentElement.clientWidth;
        const h = document.documentElement.scrollHeight;

        // Convert document coordinates to SVG coordinates (see top comment).
        const pageEl = document.querySelector(".page");
        pageOffset = pageEl
            ? pageEl.getBoundingClientRect().top + window.scrollY
            : 0;
        const masthead = document.querySelector(".masthead");
        trailStartY = masthead
            ? (masthead.getBoundingClientRect().bottom + window.scrollY) - pageOffset
            : 0;

        trailWrap.style.height = h + "px";
        trailSvg.setAttribute("viewBox", "0 0 " + w + " " + h);
        trailSvg.setAttribute("width", w);
        trailSvg.setAttribute("height", h);

        pts = generateTrail(w, h, trailStartY);
        trailSvg.replaceChildren();

        const trace = document.createElementNS(SVG_NS, "path");
        trace.setAttribute("d", pathD(pts));
        trace.setAttribute("fill", "none");
        trace.setAttribute("stroke", "#c83a1e");
        trace.setAttribute("stroke-width", "6");
        trace.setAttribute("stroke-linecap", "round");
        trace.setAttribute("opacity", "0.08");
        trailSvg.appendChild(trace);

        const main = document.createElementNS(SVG_NS, "path");
        main.setAttribute("d", pathD(pts));
        main.setAttribute("fill", "none");
        main.setAttribute("stroke", "#c83a1e");
        main.setAttribute("stroke-width", "1.6");
        main.setAttribute("stroke-dasharray", "2.5 7");
        main.setAttribute("stroke-linecap", "round");
        main.setAttribute("opacity", "0.78");
        trailSvg.appendChild(main);

        const head = document.createElementNS(SVG_NS, "path");
        head.setAttribute("d", pathD(pts.slice(0, 3)));
        head.setAttribute("fill", "none");
        head.setAttribute("stroke", "#c83a1e");
        head.setAttribute("stroke-width", "1.6");
        head.setAttribute("stroke-linecap", "round");
        head.setAttribute("opacity", "0.78");
        trailSvg.appendChild(head);

        const strays = document.createElementNS(SVG_NS, "g");
        strays.setAttribute("fill", "#c83a1e");
        const strayCount = 0;
        const trailH = h - trailStartY;
        for (let i = 0; i < strayCount; i++) {
            const t = 0.25 + (i / strayCount) * 0.75;
            const baseY = trailStartY + t * trailH;
            const baseX = xAtY(pts, baseY);
            const dir = i % 2 === 0 ? -0.45 : 1;
            const drift = (30 + Math.pow(t, 2) * 160) * dir;
            const { minX: strayMinX, maxX: strayMaxX } = driftBounds(t, w);
            const sx = Math.max(strayMinX, Math.min(strayMaxX, baseX + drift));
            const sy = baseY + (Math.random() - 0.5) * 40;
            const c = document.createElementNS(SVG_NS, "circle");
            c.setAttribute("cx", sx);
            c.setAttribute("cy", sy);
            c.setAttribute("r", 3);
            c.setAttribute("opacity", 0.4 + t * 0.3);
            strays.appendChild(c);

            const connector = document.createElementNS(SVG_NS, "line");
            connector.setAttribute("x1", baseX);
            connector.setAttribute("y1", baseY);
            connector.setAttribute("x2", sx);
            connector.setAttribute("y2", sy);
            connector.setAttribute("stroke", "#c83a1e");
            connector.setAttribute("stroke-width", "0.7");
            connector.setAttribute("stroke-dasharray", "2 4");
            connector.setAttribute("opacity", 0.25);
            strays.appendChild(connector);
        }
        trailSvg.appendChild(strays);

        const startPt = pts[0];
        const startGroup = document.createElementNS(SVG_NS, "g");
        const startRing = document.createElementNS(SVG_NS, "circle");
        startRing.setAttribute("cx", startPt.x);
        startRing.setAttribute("cy", startPt.y);
        startRing.setAttribute("r", 9);
        startRing.setAttribute("fill", "none");
        startRing.setAttribute("stroke", "#2d3d2a");
        startRing.setAttribute("stroke-width", 1);
        startRing.setAttribute("stroke-dasharray", "2 3");
        startGroup.appendChild(startRing);
        const startDot = document.createElementNS(SVG_NS, "circle");
        startDot.setAttribute("cx", startPt.x);
        startDot.setAttribute("cy", startPt.y);
        startDot.setAttribute("r", 2.5);
        startDot.setAttribute("fill", "#2d3d2a");
        startGroup.appendChild(startDot);
        trailSvg.appendChild(startGroup);

        const endPt = pts[pts.length - 1];
        const endGroup = document.createElementNS(SVG_NS, "g");
        endGroup.setAttribute("transform", "translate(" + endPt.x + ", " + (endPt.y - 12) + ") rotate(-14)");
        endGroup.setAttribute("stroke", "#c83a1e");
        endGroup.setAttribute("stroke-width", 1.5);
        endGroup.setAttribute("stroke-linecap", "round");
        const arms = ["M-9,0 L9,0", "M0,-9 L0,9", "M-6,-6 L6,6", "M-6,6 L6,-6"];
        for (const d of arms) {
            const p = document.createElementNS(SVG_NS, "path");
            p.setAttribute("d", d);
            endGroup.appendChild(p);
        }
        trailSvg.appendChild(endGroup);
    }

    /*
     * placeHere()
     *
     * Places the decorative #here ring on the trail at its fixed vertical
     * position. The ring is pinned at top: 22vh in CSS and does NOT follow
     * the trail during scroll (intentionally static), so we only compute
     * its x once per build. On scroll the trail moves under it, which is
     * fine: the ring is decorative, not a live tracker.
     */
    function placeHere() {
        if (!here) return;
        const vh = window.innerHeight;
        const targetY = window.scrollY + vh * 0.22 - pageOffset;
        const x = xAtY(pts, targetY);
        here.style.left = x + "px";
    }

    // ========================================================================
    // BOOTSTRAP + EVENT WIRING
    // ========================================================================

    buildTrail();
    placeHere();

    // Debounced rebuild on resize so we aren't regenerating 140 points and
    // re-painting the SVG on every intermediate pixel during a window drag.
    let rebuildTimer;
    function scheduleRebuild() {
        clearTimeout(rebuildTimer);
        rebuildTimer = setTimeout(() => {
            buildTrail();
            placeHere();
        }, 120);
    }
    window.addEventListener("resize", scheduleRebuild);
    if (window.ResizeObserver) {
        // Catches layout-driven size changes that don't trigger `resize`,
        // like font-swap reflows or content being added/removed dynamically.
        new ResizeObserver(scheduleRebuild).observe(document.body);
    }

    // Fade-in animation for posts as they scroll into view. The `.in` class
    // is styled in style.css to trigger the transition. Left over from the
    // posts list even though the list is currently commented out in
    // index.html, so this is a no-op until the list comes back.
    const io = new IntersectionObserver((entries) => {
        entries.forEach((e) => e.isIntersecting && e.target.classList.add("in"));
    }, { threshold: 0.15 });
    document.querySelectorAll(".post").forEach((p) => io.observe(p));
})();
