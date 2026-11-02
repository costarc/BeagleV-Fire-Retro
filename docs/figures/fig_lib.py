"""Small drawing helpers for the paper's diagrams (matplotlib only): boxes, arrows, labels on a 0..W x 0..H grid."""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Rectangle

PAL = {
    "host":   ("#E8EEF7", "#3B5B92"),   # Linux side
    "fabric": ("#E6F4F1", "#1E7B6B"),   # fabric glue
    "shared": ("#FFF1D6", "#B7791F"),   # shared resources
    "m_z80":  ("#E7F0FF", "#2F5FB3"),   # Z80 machines
    "m_6809": ("#F3E8FF", "#7A3FB0"),   # CP-400
    "m_soft": ("#FDE8E8", "#B03A3A"),   # soft CPU / host emulated
    "ext":    ("#F2F2F2", "#666666"),   # outside world
    "warn":   ("#FFE3E3", "#C0392B"),
    "ok":     ("#E3F6E8", "#2E8B57"),
    "none":   ("#FFFFFF", "#444444"),
}
INK = "#222222"


def canvas(w, h, scale=0.068):
    """A figure whose axes are a w x h grid (units = grid cells); scale = inches per unit."""
    fig = plt.figure(figsize=(w * scale, h * scale), dpi=200)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, w)
    ax.set_ylim(0, h)
    ax.axis("off")
    return fig, ax


def _t(s):
    return s.replace("$", r"\$")


def box(ax, x, y, w, h, text="", kind="none", fs=7.5, bold=False, align="center", lw=1.2, ls="-", r=0.8, valign="center", color=None):
    fc, ec = PAL[kind]
    p = FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0,rounding_size=%s" % r, fc=fc, ec=ec, lw=lw, ls=ls)
    ax.add_patch(p)
    if text:
        tx = x + w / 2 if align == "center" else x + 1.0
        ty = y + h / 2 if valign == "center" else y + h - 1.0
        ax.text(tx, ty, _t(text), ha=align, va="center" if valign == "center" else "top", fontsize=fs,
                fontweight="bold" if bold else "normal", color=color or INK, linespacing=1.25)
    return (x, y, w, h)


def group(ax, x, y, w, h, title, kind="none", fs=8, lw=1.0):
    fc, ec = PAL[kind]
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0,rounding_size=1.2", fc="none", ec=ec, lw=lw, ls=(0, (4, 3))))
    ax.text(x + 1.2, y + h - 0.8, _t(title), ha="left", va="top", fontsize=fs, fontweight="bold", color=ec)


def label(ax, x, y, text, fs=7.5, ha="center", va="center", color=INK, bold=False, rot=0, italic=False):
    ax.text(x, y, _t(text), ha=ha, va=va, fontsize=fs, color=color, fontweight="bold" if bold else "normal", rotation=rot,
            fontstyle="italic" if italic else "normal", linespacing=1.25)


def arrow(ax, p, q, text="", fs=6.8, both=False, color="#333333", lw=1.2, ls="-", tpos=0.5, toff=(0, 1.4), rad=0.0, ha="center", style=None):
    st = style or ("<|-|>" if both else "-|>")
    a = FancyArrowPatch(p, q, arrowstyle=st, mutation_scale=9, lw=lw, color=color, ls=ls,
                        connectionstyle="arc3,rad=%s" % rad, shrinkA=0, shrinkB=0)
    ax.add_patch(a)
    if text:
        mx = p[0] + (q[0] - p[0]) * tpos + toff[0]
        my = p[1] + (q[1] - p[1]) * tpos + toff[1]
        ax.text(mx, my, _t(text), ha=ha, va="center", fontsize=fs, color=color, linespacing=1.2,
                bbox=dict(fc="white", ec="none", pad=0.6, alpha=0.9))


def line(ax, pts, color="#333333", lw=1.0, ls="-"):
    ax.plot([p[0] for p in pts], [p[1] for p in pts], color=color, lw=lw, ls=ls, solid_capstyle="round")


def save(fig, name):
    fig.savefig(name, dpi=200, facecolor="white")
    plt.close(fig)
