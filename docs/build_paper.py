"""Builds docs/retro-computers-technical-paper.odt (and the PDF) from the content_*.py block lists.

    python build_paper.py            # odt + pdf (two passes: the contents page numbers come from the first PDF)
    python build_paper.py --no-pdf   # odt only

Blocks (tuples):  ("h1", text) ("h2", text) ("h3", text) ("p", text) ("ul", [text]) ("ol", [text])
  ("table", [header cells], [[row cells]], [column widths in cm], caption or None)
  ("code", text) ("fig", png name, caption, width cm) ("note", text) ("pagebreak",) ("toc",)
Inline: **bold**  *italic*  `code`
"""
import os
import re
import subprocess
import sys

from odf.opendocument import OpenDocumentText
from odf import style, text, table, draw
from odf.style import (Style, TextProperties, ParagraphProperties, TableColumnProperties, TableCellProperties,
                       TableProperties, TableRowProperties, GraphicProperties, PageLayout, PageLayoutProperties, MasterPage, Footer,
                       FooterStyle, HeaderFooterProperties, TabStops, TabStop, ListLevelProperties)
from odf.text import P, H, Span, List, ListItem, ListStyle, ListLevelStyleBullet, ListLevelStyleNumber, PageNumber, Tab, S
from odf.table import Table, TableColumn, TableRow, TableCell
from odf.draw import Frame, Image
from PIL import Image as PILImage

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
FIGS = os.path.join(HERE, "figures")
NAME = "retro-computers-technical-paper"
SOFFICE = "C:/Apps/LibreOffice/program/soffice.exe"
TEXTW = 17.0   # cm

BODY_FONT = "Liberation Serif"
HEAD_FONT = "Liberation Sans"
MONO_FONT = "Liberation Mono"
ACCENT = "#1F4E79"


def load_blocks():
    import content_a, content_b, content_c, content_d
    return content_a.BLOCKS + content_b.BLOCKS + content_c.BLOCKS + content_d.BLOCKS


class Builder:
    def __init__(self, blocks, toc_pages=None):
        self.blocks = blocks
        self.toc_pages = toc_pages or {}
        self.doc = OpenDocumentText()
        self.fig_no = 0
        self.tab_no = 0
        self.ncol_styles = 0
        self.headings = []      # (level, text)
        self.styles()

    # ------------------------------------------------------------------ styles
    def pstyle(self, name, parent=None, auto=False, **kw):
        s = Style(name=name, family="paragraph", parentstylename=parent) if parent else Style(name=name, family="paragraph")
        pp = {k[3:]: v for k, v in kw.items() if k.startswith("pp_")}
        tp = {k[3:]: v for k, v in kw.items() if k.startswith("tp_")}
        if pp:
            s.addElement(ParagraphProperties(**pp))
        if tp:
            s.addElement(TextProperties(**tp))
        (self.doc.automaticstyles if auto else self.doc.styles).addElement(s)
        return s

    def styles(self):
        d = self.doc
        # page
        pl = PageLayout(name="PL1")
        pl.addElement(PageLayoutProperties(pagewidth="21cm", pageheight="29.7cm", margintop="1.8cm", marginbottom="1.5cm",
                                           marginleft="2cm", marginright="2cm", printorientation="portrait"))
        fst = FooterStyle()
        fst.addElement(HeaderFooterProperties(minheight="0.6cm", margintop="0.3cm"))
        pl.addElement(fst)
        d.automaticstyles.addElement(pl)
        mp = MasterPage(name="Standard", pagelayoutname=pl)
        ft = Footer()
        ft.addElement(P(stylename="Footer", text=""))
        mp.addElement(ft)
        d.masterstyles.addElement(mp)
        self.footer_p = ft.childNodes[0]
        self.footer_p.addElement(Span(stylename="FooterText", text="Retro Computers on the BeagleV-Fire"))
        self.footer_p.addElement(Tab())
        self.footer_p.addElement(Span(stylename="FooterText", text="Page "))
        pn = Span(stylename="FooterText")
        pn.addElement(PageNumber(selectpage="current", text="1"))
        self.footer_p.addElement(pn)

        # default paragraph
        self.pstyle("Standard", pp_marginbottom="0.0cm")
        self.pstyle("Footer", parent="Standard", pp_textalign="start")
        # footer tab stop: right aligned at the text width
        fs = [s for s in d.styles.childNodes if getattr(s, "getAttribute", None) and s.getAttribute("name") == "Footer"][0]
        pp = [c for c in fs.childNodes if c.qname[1] == "paragraph-properties"][0]
        tabs = TabStops()
        tabs.addElement(TabStop(position="%scm" % TEXTW, type="right"))
        pp.addElement(tabs)
        fts = Style(name="FooterText", family="text")
        fts.addElement(TextProperties(fontfamily=HEAD_FONT, fontsize="8pt", color="#666666"))
        d.styles.addElement(fts)

        body = dict(tp_fontfamily=BODY_FONT, tp_fontsize="10.5pt")
        self.pstyle("Text_20_body", parent="Standard", pp_margintop="0cm", pp_marginbottom="0.22cm", pp_textalign="justify",
                    pp_lineheight="125%", pp_orphans="2", pp_widows="2", **body)
        self.pstyle("Title", parent="Standard", pp_marginbottom="0.2cm", pp_textalign="start",
                    tp_fontfamily=HEAD_FONT, tp_fontsize="23pt", tp_fontweight="bold", tp_color=ACCENT)
        self.pstyle("Subtitle", parent="Standard", pp_marginbottom="0.35cm", pp_textalign="start",
                    tp_fontfamily=HEAD_FONT, tp_fontsize="12pt", tp_color="#444444")
        self.pstyle("Meta", parent="Standard", pp_marginbottom="0.5cm", tp_fontfamily=HEAD_FONT, tp_fontsize="8.5pt", tp_color="#666666")
        self.pstyle("Heading_20_1", parent="Standard", pp_margintop="0.55cm", pp_marginbottom="0.22cm", pp_keepwithnext="always",
                    pp_breakbefore="auto", tp_fontfamily=HEAD_FONT, tp_fontsize="16pt", tp_fontweight="bold", tp_color=ACCENT)
        self.pstyle("Heading_20_2", parent="Standard", pp_margintop="0.4cm", pp_marginbottom="0.15cm", pp_keepwithnext="always",
                    tp_fontfamily=HEAD_FONT, tp_fontsize="12.5pt", tp_fontweight="bold", tp_color="#222222")
        self.pstyle("Heading_20_3", parent="Standard", pp_margintop="0.3cm", pp_marginbottom="0.1cm", pp_keepwithnext="always",
                    tp_fontfamily=HEAD_FONT, tp_fontsize="10.5pt", tp_fontweight="bold", tp_color="#333333")
        self.pstyle("Code", parent="Standard", pp_marginleft="0.3cm", pp_marginright="0.3cm", pp_margintop="0cm", pp_marginbottom="0cm",
                    pp_backgroundcolor="#F3F5F8", pp_lineheight="108%", tp_fontfamily=MONO_FONT, tp_fontsize="7.2pt", tp_color="#1B1B1B")
        self.pstyle("CodeEnd", parent="Code", pp_marginbottom="0.25cm")
        self.pstyle("Caption", parent="Standard", pp_textalign="center", pp_marginbottom="0.35cm", pp_margintop="0.08cm",
                    tp_fontfamily=HEAD_FONT, tp_fontsize="8.5pt", tp_color="#444444")
        self.pstyle("TabCaption", parent="Standard", pp_textalign="start", pp_marginbottom="0.1cm", pp_margintop="0.25cm", pp_keepwithnext="always",
                    tp_fontfamily=HEAD_FONT, tp_fontsize="8.5pt", tp_color="#444444")
        self.pstyle("Figure", parent="Standard", pp_textalign="center", pp_keepwithnext="always", pp_margintop="0.15cm")
        self.pstyle("TableText", parent="Standard", pp_textalign="start", pp_margintop="0.04cm", pp_marginbottom="0.04cm",
                    tp_fontfamily=HEAD_FONT, tp_fontsize="8.3pt")
        self.pstyle("TableHead", parent="TableText", tp_fontweight="bold", tp_color="#1B2F4B")
        self.pstyle("Note", parent="Standard", pp_marginleft="0.3cm", pp_marginright="0.3cm", pp_margintop="0.1cm", pp_marginbottom="0.3cm",
                    pp_backgroundcolor="#FFF6DD", pp_padding="0.18cm", pp_border="0.5pt solid #D9B44A", pp_textalign="justify",
                    pp_lineheight="120%", tp_fontfamily=BODY_FONT, tp_fontsize="9.8pt")
        self.pstyle("ListPara", parent="Standard", pp_textalign="justify", pp_marginbottom="0.1cm", pp_lineheight="120%", **body)
        self.pstyle("TOCHead", parent="Standard", pp_margintop="0.5cm", pp_marginbottom="0.2cm", tp_fontfamily=HEAD_FONT,
                    tp_fontsize="13pt", tp_fontweight="bold", tp_color=ACCENT)
        for lvl, (ind, fw, fs_) in {1: ("0cm", "bold", "9.5pt"), 2: ("0.6cm", "normal", "8.8pt")}.items():
            s = self.pstyle("TOC%d" % lvl, parent="Standard", pp_marginleft=ind, pp_marginbottom="0.03cm", pp_margintop="0.03cm" if lvl == 1 else "0cm",
                            tp_fontfamily=HEAD_FONT, tp_fontsize=fs_, tp_fontweight=fw)
            pp = [c for c in s.childNodes if c.qname[1] == "paragraph-properties"][0]
            tabs = TabStops()
            tabs.addElement(TabStop(position="%scm" % TEXTW, type="right", leaderstyle="dotted", leadertext="."))
            pp.addElement(tabs)
        # text styles
        for nm, kw in (("Strong", dict(fontweight="bold")), ("Emph", dict(fontstyle="italic")),
                       ("CodeInline", dict(fontfamily=MONO_FONT, fontsize="9pt", color="#7A1F1F"))):
            st = Style(name=nm, family="text")
            st.addElement(TextProperties(**kw))
            d.styles.addElement(st)
        # lists
        ls = ListStyle(name="Bul")
        for lvl in (1, 2):
            lb = ListLevelStyleBullet(level=lvl, bulletchar="\u2022" if lvl == 1 else "\u2013")
            lb.addElement(ListLevelProperties(spacebefore="%.2fcm" % (0.3 * lvl), minlabelwidth="0.45cm"))
            ls.addElement(lb)
        d.automaticstyles.addElement(ls)
        ns = ListStyle(name="Num")
        ln = ListLevelStyleNumber(level=1, numformat="1", numsuffix=".")
        ln.addElement(ListLevelProperties(spacebefore="0.3cm", minlabelwidth="0.6cm"))
        ns.addElement(ln)
        d.automaticstyles.addElement(ns)
        # table
        ts = Style(name="Tbl", family="table")
        ts.addElement(TableProperties(width="%scm" % TEXTW, align="left", margintop="0cm", marginbottom="0.35cm"))
        d.automaticstyles.addElement(ts)
        rs = Style(name="TblRow", family="table-row")
        rs.addElement(TableRowProperties(keeptogether="always"))
        d.automaticstyles.addElement(rs)
        self.rowstyle = rs
        for nm, bg in (("TblHead", "#E3EAF4"), ("TblCell", "#FFFFFF"), ("TblCellAlt", "#F7F8FA")):
            cs = Style(name=nm, family="table-cell")
            cs.addElement(TableCellProperties(border="0.4pt solid #A9B4C4", padding="0.08cm", backgroundcolor=bg))
            d.automaticstyles.addElement(cs)
        # picture frame
        fr = Style(name="Fr1", family="graphic")
        fr.addElement(GraphicProperties(anchortype="as-char", verticalpos="top", verticalrel="baseline", horizontalpos="center",
                                        horizontalrel="paragraph", wrap="none", border="none"))
        d.automaticstyles.addElement(fr)
        self.fr1 = fr

    # ------------------------------------------------------------------ inline markup
    TOKEN = re.compile(r"(\*\*.+?\*\*|`[^`]+`|\*[^*\s][^*]*?\*)")

    def inline(self, parent, txt):
        for part in self.TOKEN.split(txt):
            if not part:
                continue
            if part.startswith("**") and part.endswith("**") and len(part) > 4:
                parent.addElement(Span(stylename="Strong", text=part[2:-2]))
            elif part.startswith("`") and part.endswith("`"):
                parent.addElement(Span(stylename="CodeInline", text=part[1:-1]))
            elif part.startswith("*") and part.endswith("*") and len(part) > 2:
                parent.addElement(Span(stylename="Emph", text=part[1:-1]))
            else:
                parent.addText(part)

    def code_line(self, parent, line):
        # keep runs of spaces
        i = 0
        while i < len(line):
            if line[i] == " " and (i == 0 or line[i - 1] == " " or (i + 1 < len(line) and line[i + 1] == " ")):
                j = i
                while j < len(line) and line[j] == " ":
                    j += 1
                parent.addElement(S(c=j - i))
                i = j
            else:
                j = i
                while j < len(line) and line[j] != " ":
                    j += 1
                    if j < len(line) and line[j] == " " and j + 1 < len(line) and line[j + 1] != " ":
                        j += 1
                parent.addText(line[i:j])
                i = j

    # ------------------------------------------------------------------ blocks
    def add(self, el):
        self.doc.text.addElement(el)

    def build(self):
        for blk in self.blocks:
            kind = blk[0]
            getattr(self, "b_" + kind)(*blk[1:])
        return self.doc

    def b_title(self, t, sub, meta):
        self.add(P(stylename="Title", text=t))
        self.add(P(stylename="Subtitle", text=sub))
        self.add(P(stylename="Meta", text=meta))

    def b_h1(self, t):
        self.headings.append((1, t))
        h = H(outlinelevel=1, stylename="Heading_20_1")
        h.addText(t)
        self.add(h)

    def b_h2(self, t):
        self.headings.append((2, t))
        h = H(outlinelevel=2, stylename="Heading_20_2")
        h.addText(t)
        self.add(h)

    def b_h3(self, t):
        h = H(outlinelevel=3, stylename="Heading_20_3")
        h.addText(t)
        self.add(h)

    def b_p(self, t):
        p = P(stylename="Text_20_body")
        self.inline(p, t)
        self.add(p)

    def b_note(self, t):
        p = P(stylename="Note")
        self.inline(p, t)
        self.add(p)

    def b_ul(self, items):
        lst = List(stylename="Bul")
        for it in items:
            li = ListItem()
            if isinstance(it, (list, tuple)):      # (text, [subitems])
                p = P(stylename="ListPara")
                self.inline(p, it[0])
                li.addElement(p)
                sub = List()
                for s in it[1]:
                    sli = ListItem()
                    sp = P(stylename="ListPara")
                    self.inline(sp, s)
                    sli.addElement(sp)
                    sub.addElement(sli)
                li.addElement(sub)
            else:
                p = P(stylename="ListPara")
                self.inline(p, it)
                li.addElement(p)
            lst.addElement(li)
        self.add(lst)

    def b_ol(self, items):
        lst = List(stylename="Num")
        for it in items:
            li = ListItem()
            p = P(stylename="ListPara")
            self.inline(p, it)
            li.addElement(p)
            lst.addElement(li)
        self.add(lst)

    def b_code(self, t):
        lines = t.strip("\n").split("\n")
        for i, ln in enumerate(lines):
            p = P(stylename="CodeEnd" if i == len(lines) - 1 else "Code")
            if ln.strip() == "":
                p.addElement(S(c=1))
            else:
                self.code_line(p, ln)
            self.add(p)

    def b_pagebreak(self):
        s = Style(name="PB%d" % len(self.doc.automaticstyles.childNodes), family="paragraph", parentstylename="Standard")
        s.addElement(ParagraphProperties(breakbefore="page"))
        self.doc.automaticstyles.addElement(s)
        self.add(P(stylename=s, text=""))

    def b_fig(self, png, caption, width):
        self.fig_no += 1
        path = os.path.join(FIGS, png)
        im = PILImage.open(path)
        w, h = im.size
        wcm = min(float(width), TEXTW)
        hcm = wcm * h / w
        href = self.doc.addPicture(path)
        p = P(stylename="Figure")
        fr = Frame(stylename=self.fr1, width="%.2fcm" % wcm, height="%.2fcm" % hcm, anchortype="as-char", name="img%d" % self.fig_no)
        fr.addElement(Image(href=href, type="simple", show="embed", actuate="onLoad"))
        p.addElement(fr)
        self.add(p)
        cp = P(stylename="Caption")
        cp.addElement(Span(stylename="Strong", text="Figure %d. " % self.fig_no))
        self.inline(cp, caption)
        self.add(cp)

    def b_table(self, head, rows, widths, caption=None):
        self.tab_no += 1
        if caption:
            cp = P(stylename="TabCaption")
            cp.addElement(Span(stylename="Strong", text="Table %d. " % self.tab_no))
            self.inline(cp, caption)
            self.add(cp)
        self.ncol_styles += 1
        tot = float(sum(widths))
        t = Table(stylename="Tbl", name="T%d" % self.tab_no)
        for i, w in enumerate(widths):
            cs = Style(name="TC%d_%d" % (self.tab_no, i), family="table-column")
            cs.addElement(TableColumnProperties(columnwidth="%.2fcm" % (TEXTW * w / tot)))
            self.doc.automaticstyles.addElement(cs)
            t.addElement(TableColumn(stylename=cs))
        tr = TableRow()
        for c in head:
            tc = TableCell(stylename="TblHead", valuetype="string")
            p = P(stylename="TableHead")
            self.inline(p, c)
            tc.addElement(p)
            tr.addElement(tc)
        hdr = table.TableHeaderRows()
        hdr.addElement(tr)
        t.addElement(hdr)
        for ri, row in enumerate(rows):
            tr = TableRow(stylename=self.rowstyle)
            for c in row:
                tc = TableCell(stylename="TblCell" if ri % 2 == 0 else "TblCellAlt", valuetype="string")
                parts = str(c).split("\n")
                for part in parts:
                    p = P(stylename="TableText")
                    self.inline(p, part)
                    tc.addElement(p)
                tr.addElement(tc)
            t.addElement(tr)
        self.add(t)
        self.add(P(stylename="Standard", text=""))

    def b_toc(self):
        self.add(P(stylename="TOCHead", text="Contents"))
        for lvl, t in self.toc_entries:
            pg = self.toc_pages.get(t, "")
            p = P(stylename="TOC%d" % lvl)
            p.addText(t)
            p.addElement(Tab())
            p.addText(str(pg))
            self.add(p)

    def collect_headings(self):
        self.toc_entries = [(b[0] == "h2" and 2 or 1, b[1]) for b in self.blocks if b[0] in ("h1", "h2")]

    def save(self, path):
        self.collect_headings()
        self.build()
        self.doc.meta.addElement(__import__("odf.dc", fromlist=["Title"]).Title(text="Retro Computers on the BeagleV-Fire"))
        self.doc.save(path)


def pdf_pages(odt_path, out_dir):
    subprocess.run([SOFFICE, "--headless", "--convert-to", "pdf", "--outdir", out_dir, odt_path], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return os.path.join(out_dir, os.path.splitext(os.path.basename(odt_path))[0] + ".pdf")


def main():
    pdf = "--no-pdf" not in sys.argv
    blocks = load_blocks()
    odt = os.path.join(HERE, NAME + ".odt")
    b = Builder(blocks)
    b.save(odt)
    if not pdf:
        return
    out = HERE
    pdf_path = pdf_pages(odt, out)
    pages = {}
    import fitz
    d = fitz.open(pdf_path)
    texts = [d[i].get_text() for i in range(len(d))]
    # first page after the contents that starts the body: the one whose text contains the first h1 and NOT the dotted contents
    first = None
    for i, tx in enumerate(texts):
        if "...." not in tx and b.toc_entries[0][1] in tx:
            first = i
            break
    start = first if first is not None else 0
    for lvl, t in b.toc_entries:
        for i in range(start, len(d)):
            lines = [ln.strip() for ln in texts[i].split("\n")]
            if t in lines or t[:38] in " ".join(lines):
                pages[t] = i + 1
                start = i
                break
    b2 = Builder(blocks, toc_pages=pages)
    b2.save(odt)
    pdf_path = pdf_pages(odt, out)
    d = fitz.open(pdf_path)
    print("pages:", len(d), " headings located:", len(pages), "of", len(b.toc_entries))
    print("missing:", [t for _, t in b.toc_entries if t not in pages])


if __name__ == "__main__":
    main()
