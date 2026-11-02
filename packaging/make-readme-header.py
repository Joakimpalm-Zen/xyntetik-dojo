#!/usr/bin/env python3
"""The README header SVGs (light and dark): the Dojo mark and the wordmark, from the same numbers as
Theme.swift. Run from the repository root: python3 packaging/make-readme-header.py"""
import math
import pathlib

OUT = pathlib.Path(__file__).resolve().parent / "readme"
FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"


def mark(scale, ox, oy):
    pts = []
    d = 245
    while d >= 300 - 360:
        a = math.radians(d)
        pts.append((ox + (50 + 40 * math.cos(a)) * scale, oy + (50 + 40 * math.sin(a)) * scale))
        d -= 1
    path = "M " + " L ".join(f"{x:.1f} {y:.1f}" for x, y in pts)
    p = lambda x, y: f"{ox + x * scale:.1f} {oy + y * scale:.1f}"
    g = f'<path d="{path}" fill="none" stroke="url(#g)" stroke-width="{9 * scale:.1f}" stroke-linecap="round"/>'
    # the torii: kasagi (curved top beam), nuki (tie beam), two pillars
    red = "#D8432B"
    g += f'<path d="M {p(29, 30)} Q {p(50, 36)} {p(71, 30)}" fill="none" stroke="{red}" stroke-width="{4.5 * scale:.1f}"/>'
    g += f'<path d="M {p(34, 44)} L {p(66, 44)}" stroke="{red}" stroke-width="{3.5 * scale:.1f}"/>'
    for x in (39, 61):
        g += f'<path d="M {p(x, 36)} L {p(x, 70)}" stroke="{red}" stroke-width="{4.5 * scale:.1f}"/>'
    for x, y, r, c in [(70.5, 14.9, 5.4, "#FF7A5C"), (77.8, 9.2, 2.7, "#FF9A80"), (82.6, 4.8, 1.6, "#FFBBA8")]:
        g += f'<circle cx="{ox + x * scale:.1f}" cy="{oy + y * scale:.1f}" r="{r * scale:.1f}" fill="{c}"/>'
    return g


def header(ink, muted, teal):
    s = 0.72
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 96" width="300" height="96" role="img" aria-label="Xyntetik Dojo"><title>Xyntetik Dojo</title>'
            f'<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#159A89"/><stop offset="1" stop-color="#2FD0B9"/></linearGradient></defs>'
            f'{mark(s, 8, 12)}<text x="100" y="46" font-family="{FONT}" font-size="34" font-weight="600" letter-spacing="-1"><tspan fill="{teal}">x</tspan><tspan fill="{ink}">yntetik</tspan></text>'
            f'<text x="101" y="74" font-family="{FONT}" font-size="19" font-weight="500" fill="{muted}">Dojo</text></svg>\n')


def social():
    """The repository's social preview (1280 x 640, GitHub's size), laid out like the Runner card."""
    s = 3.25
    t = lambda y, size, weight, fill, text, ls=0: (
        f'<text x="630" y="{y}" font-family="{FONT}" font-size="{size}" font-weight="{weight}" '
        f'letter-spacing="{ls}" fill="{fill}">{text}</text>')
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1280 640" width="1280" height="640" role="img" aria-label="Xyntetik Dojo"><title>Xyntetik Dojo</title>'
            '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#159A89"/><stop offset="1" stop-color="#2FD0B9"/></linearGradient></defs>'
            '<rect width="1280" height="640" fill="#FFFFFF"/>'
            + mark(s, 390 - 50 * s, 325 - 50 * s)
            + t(238, 21, 500, "#6B7A81", "XYNTETIK", 5)
            + t(332, 104, 700, "#16232A", "Dojo", -2)
            + t(392, 31, 500, "#3A4A51", "Your agent harnesses in one window.")
            + '<rect x="630" y="421" width="56" height="4" rx="2" fill="#FFA033"/>'
            + t(466, 20, 500, "#6B7A81", "LOCAL AND OVER SSH, ON ONE BUS", 3)
            + '</svg>\n')


(OUT / "header-light.svg").write_text(header("#16232A", "#6B7A81", "#14A08F"))
(OUT / "header-dark.svg").write_text(header("#E8ECEA", "#8C9A98", "#3ED2BD"))
(OUT / "social.svg").write_text(social())
print("wrote", OUT / "header-light.svg", "header-dark.svg and social.svg")
