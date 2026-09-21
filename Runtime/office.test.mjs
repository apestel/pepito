import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

// Also runnable against the signed bundle using PEPITO_TEST_RUNTIME.
const { runScript } = await import(process.env.PEPITO_TEST_RUNTIME
  ? pathToFileURL(join(process.env.PEPITO_TEST_RUNTIME, 'script-runner.mjs')).href
  : './script-runner.mjs');

test('Office creation and subsequent editing work offline in separate Python calls', { skip: process.platform !== 'darwin' }, async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'pepito-office-')));
  const run = code => runScript({ root, language: 'python', code, network: false });
  try {
    const created = await run(`
import xlsxwriter
from docx import Document
from pptx import Presentation
from pptx.chart.data import CategoryChartData
from pptx.enum.chart import XL_CHART_TYPE
from pptx.util import Inches
from PIL import Image

Image.new('RGB', (32, 32), 'blue').save('image.png')
with xlsxwriter.Workbook('report.xlsx') as book:
    sheet = book.add_worksheet('Suivi')
    sheet.write('A1', 'Budget', book.add_format({'bold': True}))
    sheet.write('A2', 21)
    sheet.write_formula('B2', '=A2*2', None, 42)
    chart = book.add_chart({'type': 'column'})
    chart.add_series({'values': '=Suivi!$A$2:$B$2'})
    sheet.insert_chart('D2', chart)
doc = Document()
doc.add_heading('Compte rendu', 0)
doc.add_table(rows=1, cols=1).cell(0, 0).text = 'Décision validée'
doc.add_picture('image.png')
doc.save('report.docx')
deck = Presentation()
slide = deck.slides.add_slide(deck.slide_layouts[5])
slide.shapes.title.text = 'Résultats'
data = CategoryChartData()
data.categories = ['Projet']
data.add_series('Budget', [42])
slide.shapes.add_chart(XL_CHART_TYPE.COLUMN_CLUSTERED, Inches(1), Inches(2), Inches(5), Inches(3), data)
deck.save('report.pptx')
`);
    assert.equal(created.exitCode, 0, created.stderr);
    const edited = await run(`
from openpyxl import load_workbook
from docx import Document
from pptx import Presentation
assert load_workbook('report.xlsx', data_only=True)['Suivi']['B2'].value == 42
book = load_workbook('report.xlsx')
assert book['Suivi']['A1'].font.bold
assert book['Suivi']['B2'].value == '=A2*2'
assert len(book['Suivi']._charts) == 1
book['Suivi']['A2'] = 30
book.save('edited.xlsx')
assert load_workbook('edited.xlsx')['Suivi']['A2'].value == 30
doc = Document('report.docx')
assert doc.tables[0].cell(0, 0).text == 'Décision validée'
assert len(doc.inline_shapes) == 1
doc.add_paragraph('Suivi ajouté')
doc.save('edited.docx')
assert Document('edited.docx').paragraphs[-1].text == 'Suivi ajouté'
deck = Presentation('report.pptx')
assert deck.slides[0].shapes.title.text == 'Résultats'
chart = next(s.chart for s in deck.slides[0].shapes if s.has_chart)
assert chart.series[0].values[0] == 42
deck.slides[0].shapes.title.text = 'Résultats validés'
deck.save('edited.pptx')
assert Presentation('edited.pptx').slides[0].shapes.title.text == 'Résultats validés'
`);
    assert.equal(edited.exitCode, 0, edited.stderr);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
