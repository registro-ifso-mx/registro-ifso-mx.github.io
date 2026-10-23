// Registro Bariátrico México · PDFs de la sección Constancias.
// Dos documentos: (1) formato de carta del hospital, ya llenado, para que el hospital lo imprima en su membrete,
// lo firme y lo selle; (2) la constancia anual de participación con folio y código QR verificable.
// Las bibliotecas (pdf-lib y generador de QR) se cargan solo cuando se usan.
(function(){
  'use strict';
  const MESES = ['Enero','Febrero','Marzo','Abril','Mayo','Junio','Julio','Agosto','Septiembre','Octubre','Noviembre','Diciembre'];
  const LIBS = {
    pdf: 'https://cdnjs.cloudflare.com/ajax/libs/pdf-lib/1.17.1/pdf-lib.min.js',
    qr: 'https://cdnjs.cloudflare.com/ajax/libs/qrcode-generator/1.4.4/qrcode.min.js'
  };
  const cargada = {};
  function lib(src){
    if (cargada[src]) return cargada[src];
    cargada[src] = new Promise((ok, no) => { const s = document.createElement('script'); s.src = src; s.onload = ok; s.onerror = () => { delete cargada[src]; no(new Error('No se pudo cargar ' + src)); }; document.head.appendChild(s); });
    return cargada[src];
  }
  let logoP = null;
  const logo = () => logoP || (logoP = fetch('../logo.jpg').then(r => r.arrayBuffer()).catch(() => null));
  const fechaLarga = d => d.toLocaleDateString('es-MX', { day: 'numeric', month: 'long', year: 'numeric' });
  const o = (v, alt) => (v && String(v).trim()) || alt;
  const mm = v => v * 72 / 25.4;              // milímetros → puntos
  // Caracteres fuera de WinAnsi (las fuentes estándar no los tienen) se sustituyen.
  const limpio = s => String(s ?? '').replace(/[–—]/g, '-').replace(/[“”]/g, '"').replace(/[‘’]/g, "'").replace(/[^\x00-\xff]/g, '?');

  // Lienzo con origen arriba-izquierda en mm, sobre una página de pdf-lib.
  function lienzo(page, fonts){
    const H = page.getHeight();
    const L = {
      font: fonts.reg, size: 11, color: [0, 0, 0],
      set(f, s, c){ if (f) L.font = f; if (s) L.size = s; if (c) L.color = c; },
      rgb: c => window.PDFLib.rgb(c[0] / 255, c[1] / 255, c[2] / 255),
      ancho: (t, s) => L.font.widthOfTextAtSize(limpio(t), s || L.size),
      texto(t, x, y, opt){ // y = línea base, en mm
        opt = opt || {}; t = limpio(t); const s = opt.size || L.size, f = opt.font || L.font; let px = mm(x);
        const w = f.widthOfTextAtSize(t, s);
        if (opt.align === 'right') px -= w; else if (opt.align === 'center') px -= w / 2;
        page.drawText(t, { x: px, y: H - mm(y), size: s, font: f, color: L.rgb(opt.color || L.color) });
      },
      // Divide un texto en líneas que caben en w mm; devuelve el arreglo.
      lineas(t, w, s, f){ s = s || L.size; f = f || L.font; const out = []; limpio(t).split('\n').forEach(par => { let cur = '';
        par.split(' ').forEach(pal => { const p = cur ? cur + ' ' + pal : pal; if (f.widthOfTextAtSize(p, s) > mm(w) && cur) { out.push(cur); cur = pal; } else cur = p; }); out.push(cur); }); return out; },
      // Párrafo con salto automático; devuelve la y de la siguiente línea.
      parrafo(t, x, y, w, lh, opt){ opt = opt || {}; const ls = L.lineas(t, w, opt.size, opt.font); ls.forEach((l, i) => L.texto(l, opt.align === 'center' ? x + w / 2 : x, y + i * lh, opt)); return y + ls.length * lh; },
      // Párrafo justificado (la última línea queda alineada a la izquierda).
      parrafoJ(t, x, y, w, lh, opt){ opt = opt || {}; const s = opt.size || L.size, f = opt.font || L.font; const ls = L.lineas(t, w, s, f);
        ls.forEach((l, i) => { const pal = l.split(' '); if (i === ls.length - 1 || pal.length < 2) { L.texto(l, x, y + i * lh, opt); return; }
          const tw = pal.reduce((acc, pw) => acc + f.widthOfTextAtSize(limpio(pw), s), 0); const gap = (mm(w) - tw) / (pal.length - 1); let px = mm(x);
          pal.forEach(pw => { page.drawText(limpio(pw), { x: px, y: H - mm(y + i * lh), size: s, font: f, color: L.rgb(opt.color || L.color) }); px += f.widthOfTextAtSize(limpio(pw), s) + gap; }); });
        return y + ls.length * lh; },
      rect(x, y, w, h, fill, stroke, lw){ page.drawRectangle({ x: mm(x), y: H - mm(y) - mm(h), width: mm(w), height: mm(h), color: fill ? L.rgb(fill) : undefined, borderColor: stroke ? L.rgb(stroke) : undefined, borderWidth: stroke ? (lw || 0.4) : 0 }); },
      linea(x1, y1, x2, y2, c, lw){ page.drawLine({ start: { x: mm(x1), y: H - mm(y1) }, end: { x: mm(x2), y: H - mm(y2) }, thickness: lw || 0.4, color: L.rgb(c || [120, 120, 120]) }); }
    };
    return L;
  }
  async function nuevo(){
    await lib(LIBS.pdf);
    const { PDFDocument, StandardFonts } = window.PDFLib;
    const pdf = await PDFDocument.create();
    pdf.setProducer('Registro Bariátrico México'); pdf.setCreator('registrobariatrico.com');
    const fonts = { reg: await pdf.embedFont(StandardFonts.Helvetica), bold: await pdf.embedFont(StandardFonts.HelveticaBold), mono: await pdf.embedFont(StandardFonts.CourierBold) };
    const page = pdf.addPage([mm(215.9), mm(279.4)]); // tamaño carta
    return { pdf, page, fonts, L: lienzo(page, fonts) };
  }
  async function descargar(pdf, nombre){
    const bytes = await pdf.save();
    const blob = new Blob([bytes], { type: 'application/pdf' }), url = URL.createObjectURL(blob);
    const a = document.createElement('a'); a.href = url; a.download = nombre; document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 60000);
    return bytes;
  }
  const NAVY = [6, 21, 81], VIOLETA = [132, 77, 255], GRIS = [110, 110, 120], LILA = [236, 230, 255], LILA2 = [246, 244, 255];

  // ---------- 1. Formato de carta del hospital ----------
  // d = { hospital:{nombre, licencia, firmante, cargo_firmante, telefono, correo_contacto, domicilio, municipio, entidad},
  //       socio, cedula, anio, meses:[12 números del registro], ciudad }
  async function carta(d){
    const { pdf, page, fonts, L } = await nuevo();
    const W = 215.9, M = 25, CW = W - 2 * M, LH = 5.9;
    const h = d.hospital || {};
    const total = (d.meses || []).reduce((a, b) => a + (b || 0), 0);
    const lin = v => o(v, '______________________');
    const LINEA = [205, 205, 215];
    L.set(fonts.reg, 11, [20, 20, 30]);
    let y = 44; // margen superior libre para el membrete del hospital
    L.texto(`${o(d.ciudad, lin(h.municipio))}, a ____ de ______________ de ${d.anio + 1}`, W - M, y, { align: 'right' }); y += 10;
    L.texto('Colegio Mexicano de Cirugía para la Obesidad y Enfermedades Metabólicas, A.C.', M, y, { font: fonts.bold }); y += LH;
    L.texto('Registro Bariátrico México', M, y, { font: fonts.bold }); y += LH;
    L.texto('P r e s e n t e', M, y); y += 9;
    L.texto('Asunto:', M, y, { font: fonts.bold }); L.texto(`Cirugías bariátricas y metabólicas realizadas en ${d.anio}`, M + 17, y); y += 9;
    const cuerpo = `El que suscribe, ${lin(h.firmante)}, en mi carácter de ${o(h.cargo_firmante, 'representante legal / director general')} de ${o(h.nombre, '______________________')}, con licencia sanitaria / aviso de funcionamiento ante COFEPRIS número ${lin(h.licencia)}, ubicado en ${lin(h.domicilio)}, teléfono ${lin(h.telefono)}, correo ${lin(h.correo_contacto)}, hago constar bajo protesta de decir verdad que el/la Dr(a). ${o(d.socio, '______________________')}, cédula de especialidad ${lin(d.cedula)}, realizó en este establecimiento, durante el periodo del 1 de enero al 31 de diciembre de ${d.anio}, las cirugías bariátricas y metabólicas que se indican, de acuerdo con el registro de quirófano de esta institución:`;
    y = L.parrafoJ(cuerpo, M, y, CW, LH) + 4;
    // Tabla de meses en dos columnas (líneas finas, encabezado y total con fondo claro)
    const colW = CW / 2, rowH = 6.5, x0 = M, x1 = M + colW;
    [x0, x1].forEach(x => { L.rect(x, y, colW, rowH, LILA, LINEA); L.texto('Mes', x + 4, y + 4.8, { font: fonts.bold, size: 9.5, color: NAVY }); L.texto('Cirugías', x + colW - 4, y + 4.8, { font: fonts.bold, size: 9.5, align: 'right', color: NAVY }); });
    y += rowH;
    for (let i = 0; i < 6; i++) {
      [[i, x0], [i + 6, x1]].forEach(([m, x]) => { L.rect(x, y, colW, rowH, null, LINEA); L.texto(MESES[m], x + 4, y + 4.8, { size: 10.5 }); L.texto(String(d.meses && d.meses[m] != null ? d.meses[m] : ''), x + colW - 4, y + 4.8, { size: 10.5, align: 'right' }); });
      y += rowH;
    }
    L.rect(x0, y, CW, rowH + 1, LILA2, LINEA);
    L.texto('Total anual ' + d.anio, x0 + 4, y + 5.3, { font: fonts.bold, size: 10.5, color: NAVY }); L.texto(String(total), x0 + CW - 4, y + 5.3, { font: fonts.bold, size: 11, align: 'right', color: NAVY }); y += rowH + 8;
    y = L.parrafoJ('Se extiende la presente para los fines del Registro Bariátrico México del CMCOEM. No contiene datos personales de pacientes.', M, y, CW, LH) + 7;
    L.texto('Atentamente', M, y); y += 20;
    L.linea(M, y, M + 80, y, [90, 90, 100]); L.linea(W - M - 60, y, W - M, y, [90, 90, 100]); y += 5;
    L.texto(o(h.firmante, 'Nombre y firma'), M, y, { font: fonts.bold, size: 10 }); L.texto('Sello del establecimiento', W - M - 30, y, { size: 9, align: 'center', color: GRIS }); y += 4.8;
    L.texto(o(h.cargo_firmante, 'Representante legal / Director general'), M, y, { size: 9.5, color: GRIS }); y += 4.8;
    L.parrafo(o(h.nombre, ''), M, y, 90, 4.6, { size: 9.5, color: GRIS });
    // Sello discreto del Colegio en la esquina inferior derecha
    const img = await logo();
    if (img) { try { const jpg = await pdf.embedJpg(img); page.drawImage(jpg, { x: mm(W - M - 15), y: page.getHeight() - mm(270), width: mm(15), height: mm(15) }); } catch (e) {} }
    L.texto('Registro Bariátrico México', W - M - 17, 262, { size: 7, color: [150, 150, 160], align: 'right' });
    L.texto('Formato para la constancia anual de participación', W - M - 17, 265.5, { size: 7, color: [150, 150, 160], align: 'right' });
    const nombre = `Carta_${(h.nombre || 'hospital').normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/[^\w]+/g, '_')}_${d.anio}.pdf`;
    return { pdf, nombre, save: () => descargar(pdf, nombre) };
  }

  function cartaTexto(d){
    const h = d.hospital || {}, lin = v => o(v, '[__________]');
    const total = (d.meses || []).reduce((a, b) => a + (b || 0), 0);
    const filas = MESES.map((m, i) => `${m}: ${d.meses && d.meses[i] != null ? d.meses[i] : ''}`).join('\n');
    return `${o(d.ciudad, lin(h.municipio))}, a ___ de __________ de ${d.anio + 1}

Colegio Mexicano de Cirugía para la Obesidad y Enfermedades Metabólicas, A.C.
Registro Bariátrico México
Presente

El que suscribe, ${lin(h.firmante)}, en mi carácter de ${o(h.cargo_firmante, 'representante legal / director general')} de ${lin(h.nombre)}, con licencia sanitaria / aviso de funcionamiento ante COFEPRIS número ${lin(h.licencia)}, ubicado en ${o(h.domicilio, lin([h.municipio, h.entidad].filter(Boolean).join(', ')))}, teléfono ${lin(h.telefono)}, correo ${lin(h.correo_contacto)}, hago constar bajo protesta de decir verdad que el/la Dr(a). ${lin(d.socio)}, cédula de especialidad ${lin(d.cedula)}, realizó en este establecimiento, durante el periodo del 1 de enero al 31 de diciembre de ${d.anio}, las cirugías bariátricas y metabólicas que se indican, de acuerdo con el registro de quirófano de esta institución:

${filas}
Total anual ${d.anio}: ${total}

Se extiende la presente para los fines del Registro Bariátrico México del CMCOEM. No contiene datos personales de pacientes.

______________________________
${o(h.firmante, 'Nombre y firma')}
${o(h.cargo_firmante, 'Representante legal / Director general')}
${o(h.nombre, '')}
Sello del establecimiento`;
  }

  // ---------- 2. Constancia con folio y QR ----------
  // c = { folio, anio, socio, cedula, hospitales:[{hospital, sector, cirugias}], total, auditoria, muestreado,
  //       emitida:'YYYY-MM-DD', presidente, responsable, url }
  async function constancia(c){
    await lib(LIBS.qr);
    const { pdf, page, fonts, L } = await nuevo();
    const W = 215.9, H = 279.4, M = 20, CW = W - 2 * M;
    L.rect(9, 9, W - 18, H - 18, null, VIOLETA, 2.2); L.rect(11.5, 11.5, W - 23, H - 23, null, NAVY, 0.8);
    const img = await logo();
    if (img) { try { const jpg = await pdf.embedJpg(img); page.drawImage(jpg, { x: mm(W / 2 - 24), y: page.getHeight() - mm(18 + 48), width: mm(48), height: mm(48) }); } catch (e) {} }
    let y = 74;
    L.texto('CONSTANCIA DE PARTICIPACIÓN', W / 2, y, { font: fonts.bold, size: 17, color: NAVY, align: 'center' }); y += 8;
    L.texto('REGISTRO BARIÁTRICO MÉXICO · ' + c.anio, W / 2, y, { font: fonts.bold, size: 12.5, color: NAVY, align: 'center' }); y += 7;
    L.texto('Folio ' + c.folio, W / 2, y, { font: fonts.mono, size: 10.5, color: VIOLETA, align: 'center' }); y += 12;
    L.set(fonts.reg, 11, [30, 30, 30]);
    y = L.parrafo('El Colegio Mexicano de Cirugía para la Obesidad y Enfermedades Metabólicas, A.C. hace constar que', M, y, CW, 5.6, { align: 'center', size: 10.5 }) + 5;
    y = L.parrafo(c.socio || '', M, y, CW, 7, { font: fonts.bold, size: 16, color: NAVY, align: 'center' }) + 1;
    L.texto((c.cedula ? 'Cédula de especialidad ' + c.cedula + ' · ' : '') + 'Socio del CMCOEM', W / 2, y, { size: 10.5, color: GRIS, align: 'center' }); y += 10;
    y = L.parrafo(`participó activamente en el Registro Bariátrico México durante el año ${c.anio}, con la siguiente actividad verificada mediante carta de cada hospital firmada por su representante legal o director general:`, M, y, CW, 5.6) + 4;
    const cols = [CW - 70, 32, 38], x = [M, M + cols[0], M + cols[0] + cols[1]], rowH = 7;
    L.rect(M, y, CW, rowH, LILA, [190, 190, 190]);
    L.texto('Hospital', x[0] + 3, y + 4.8, { font: fonts.bold, size: 9.5, color: NAVY }); L.texto('Sector', x[1] + 3, y + 4.8, { font: fonts.bold, size: 9.5, color: NAVY }); L.texto('Procedimientos', x[2] + cols[2] - 3, y + 4.8, { font: fonts.bold, size: 9.5, color: NAVY, align: 'right' }); y += rowH;
    (c.hospitales || []).forEach(hh => {
      const ls = L.lineas(hh.hospital || '', cols[0] - 6, 10), rh = Math.max(rowH, ls.length * 4.6 + 2.6);
      L.rect(M, y, CW, rh, null, [190, 190, 190]);
      ls.forEach((l, i) => L.texto(l, x[0] + 3, y + 4.8 + i * 4.6, { size: 10 }));
      L.texto(hh.sector || '', x[1] + 3, y + 4.8, { size: 10 }); L.texto(String(hh.cirugias ?? ''), x[2] + cols[2] - 3, y + 4.8, { size: 10, align: 'right' }); y += rh;
    });
    L.rect(M, y, CW, rowH, LILA2, [190, 190, 190]);
    L.texto('Total verificado', x[0] + 3, y + 4.8, { font: fonts.bold, size: 10 }); L.texto(String(c.total ?? ''), x[2] + cols[2] - 3, y + 4.8, { font: fonts.bold, size: 10, align: 'right' }); y += rowH + 7;
    const aud = `Auditoría ${c.anio}: ${c.auditoria ? c.auditoria.toUpperCase() : 'VERIFICADO'}`;
    y = L.parrafo(aud, M, y, CW, 5.2, { size: 10, color: [60, 60, 60] }) + 3;
    const fe = c.emitida ? new Date(c.emitida + 'T12:00:00') : new Date();
    y = L.parrafo(`Se expide en la Ciudad de México el ${fechaLarga(fe)} para los fines que al interesado convengan, en particular ante el Consejo Mexicano de Cirugía General, A.C.`, M, y, CW, 5.2, { size: 10, color: [60, 60, 60] });
    const yf = Math.min(Math.max(y + 24, 205), 228);
    L.linea(M + 4, yf, M + 78, yf); L.linea(W - M - 78, yf, W - M - 4, yf);
    L.parrafo(c.presidente || 'Presidente del CMCOEM', M + 4, yf + 5, 74, 4.6, { size: 9.5, align: 'center' });
    L.parrafo(c.responsable || 'Responsable del Registro', W - M - 78, yf + 5, 74, 4.6, { size: 9.5, align: 'center' });
    // QR
    const q = window.qrcode(0, 'M'); q.addData(c.url || ''); q.make();
    const n = q.getModuleCount(), size = 22, cell = size / n, qx = W / 2 - size / 2, qy = 240;
    for (let r = 0; r < n; r++) for (let cc = 0; cc < n; cc++) if (q.isDark(r, cc)) L.rect(qx + cc * cell, qy + r * cell, cell + 0.02, cell + 0.02, NAVY);
    L.texto('Verifique esta constancia en ' + (c.url || ''), W / 2, qy + size + 4.5, { size: 8, color: GRIS, align: 'center' });
    const nombre = `Constancia_${c.folio}.pdf`;
    return { pdf, nombre, save: () => descargar(pdf, nombre) };
  }

  window.RBM_PDF = { carta, cartaTexto, constancia, MESES };
})();
