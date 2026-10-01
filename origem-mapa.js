// Mapa de origem territorial das operações de Xis — módulo compartilhado
// Desenha: mapa urbano de Santa Maria (bolhas por bairro) + RS (cidades de fora)
// Fontes: contornos IBGE (malha oficial simplificada) e posições de bairros OpenStreetMap
(function(){
  const GAZ = [
    ["Centro",220.4,139.1],["Bonfim",198.7,141.1],["Nossa Senhora de Fátima",198.2,162.3],
    ["Noal",168.4,157],["Nossa Senhora do Rosário",196,123.2],["Carolina",192.6,111.6],
    ["Passo D'Areia",157.2,133.2],["Divina Providência",164,114.5],["Salgado Filho",181.4,96.6],
    ["Nonoai",227.1,170],["Nossa Senhora de Lourdes",246.4,172.8],["Nossa Senhora das Dores",253.1,147.6],
    ["Menino Jesus",241.5,129.5],["Chácara das Flores",186.4,78.2],["Itararé",244.4,100.9],
    ["Presidente João Goulart",270.8,126.4],["Nossa Senhora Medianeira",212.4,190.7],["Uglione",197.6,204],
    ["Duque de Caxias",188.8,186.7],["Patronato",170.2,179.1],["Renascença",142,193.8],
    ["São João",131,179.6],["Pinheiro Machado",84.7,169.2],["Tancredo Neves",54.2,172.8],
    ["Boi Morto",78.8,226.1],["Juscelino Kubitschek",119.8,159.2],["Urlândia",191.7,219],
    ["Dom Antônio Reis",233,221.3],["Nossa Senhora do Perpétuo Socorro",216.2,72],["Km 3",289.6,112.2],
    ["Pé de Plátano",358.4,142.5],["Camobi",410.8,181.3],["São José",328.6,179.3],
    ["Diácono João Luiz Pozzobon",302,245.4],["Cerrito",265,196.3],["Tomazetti",253.3,260.4],
    ["Lorenzi",218.6,279.9],["Agroindustrial",71,105.1],["Nova Santa Marta",108.4,128.3],
    ["Caturrita",136.2,90.7],["Campestre do Menino Deus",247.7,41.4],["Arroio Grande",519,43.6],["Pains",416.4,315.4]
  ];
  const RS_PATH = "M106.3,164.5 L115.1,179.0 L134.0,186.0 L141.9,178.5 L144.9,170.9 L145.0,187.6 L133.9,193.0 L126.3,203.5 L121.5,214.6 L121.6,225.0 L144.9,203.3 L154.5,177.4 L155.6,160.9 L162.0,155.7 L165.4,142.7 L173.9,137.3 L177.6,131.3 L181.1,120.1 L188.2,113.1 L183.4,100.2 L190.4,107.1 L194.7,109.4 L205.5,106.9 L201.3,115.3 L193.2,128.6 L187.6,141.8 L179.7,148.8 L165.9,161.6 L160.8,170.8 L186.8,149.2 L211.6,115.3 L216.4,101.6 L219.5,93.6 L223.6,85.0 L227.4,74.2 L218.0,73.2 L217.1,73.6 L222.6,66.8 L223.2,55.2 L230.0,52.0 L226.7,46.5 L209.0,45.3 L199.5,39.1 L192.2,29.4 L184.2,21.7 L176.2,15.8 L171.8,13.1 L167.2,12.9 L159.9,8.5 L154.3,7.6 L150.4,4.2 L142.9,6.5 L138.2,2.6 L133.4,0.0 L124.5,4.0 L119.7,3.4 L113.0,3.0 L106.3,2.0 L99.3,5.8 L92.8,10.6 L86.3,15.3 L78.4,20.5 L69.7,25.9 L64.7,31.8 L56.1,42.2 L49.8,46.9 L40.8,56.9 L33.9,67.2 L23.7,78.7 L10.5,90.9 L3.8,102.1 L6.0,108.6 L21.7,101.3 L33.0,111.3 L41.0,118.8 L46.1,134.9 L58.7,126.5 L68.4,140.7 L80.4,147.1 L91.0,151.5 Z";
  const SM_RS = [110.3,87.8];
  const CIDADES_RS = {
    "sao sepe":[117.6,103.7,"São Sepé"], "cacapava do sul":[119.6,115.6,"Caçapava do Sul"],
    "dom pedrito":[85.2,131.5,"Dom Pedrito"], "porto alegre":[185.8,99.3,"Porto Alegre"]
  };
  const norm = s => (s||'').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g,'').replace(/[^a-z0-9]/g,'');
  const normC = s => (s||'').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g,'').replace(/[^a-z0-9 ]/g,'').trim();
  const esc = s => String(s==null?'':s).replace(/[&<>"]/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
  const corDe = (n,max)=> n<=0?'#d9cfe5' : n===1?'#c9aede' : n===2?'#9b6cc0' : (n>=Math.max(3,max)?'#662382':'#7e4a9e');
  const raioDe = n => n<=0 ? 2.5 : Math.min(24, 6 + Math.sqrt(n)*5);

  // opts: { sb, svgMapa, svgRS (opcional), notaEl (opcional), kpis: fn(tot,bairros,cidades) opcional }
  window.renderOrigemXis = async function(opts){
    const SBc = opts.sb;
    const {data, error} = await SBc.from('festival_interessados').select('nome,bairro,cidade,categoria').eq('categoria','xis');
    if(error || !data) return null;
    const xis = data;
    const fora = xis.filter(i=>i.cidade);
    const regiao = xis.filter(i=>!i.cidade && i.bairro && norm(i.bairro)===norm('Outro / região'));
    const indef = xis.filter(i=>!i.cidade && !i.bairro);
    const counts = {};
    xis.filter(i=>!i.cidade && i.bairro && norm(i.bairro)!==norm('Outro / região'))
       .forEach(i=>{ const k=norm(i.bairro); counts[k]=(counts[k]||0)+1; });
    const gazPorNorm = {}; GAZ.forEach(([n,x,y])=>gazPorNorm[norm(n)]={n,x,y});
    const max = Math.max(1, ...Object.values(counts), 1);

    const elM = document.getElementById(opts.svgMapa);
    if(elM){
      let s = '<rect x="0" y="0" width="560" height="345" rx="10" fill="#faf7fc"/>';
      const comConta = [], semConta = [];
      GAZ.forEach(([n,x,y])=>{ const c=counts[norm(n)]||0; (c>0?comConta:semConta).push({n,x,y,c}); });
      semConta.forEach(p=>{ s += '<circle cx="'+p.x+'" cy="'+p.y+'" r="2.5" fill="#d9cfe5"/>'; });
      ["Arroio Grande","Pains","Tancredo Neves","Pé de Plátano"].forEach(nm=>{
        const p = gazPorNorm[norm(nm)];
        if(p && !(counts[norm(nm)]>0)) s += '<text x="'+p.x+'" y="'+(p.y+13)+'" font-size="8.5" font-weight="700" fill="#b4a8c2" text-anchor="middle">'+esc(nm)+'</text>';
      });
      comConta.sort((a,b)=>b.c-a.c).forEach(p=>{
        const r = raioDe(p.c), cor = corDe(p.c, max);
        s += '<circle cx="'+p.x+'" cy="'+p.y+'" r="'+r+'" fill="'+cor+'" fill-opacity="0.95"/>';
        const nm = p.n.replace('Nossa Senhora','N. S.');
        if(r>=13){
          s += '<text x="'+p.x+'" y="'+(p.y-2)+'" font-size="9" font-weight="800" fill="#fff" text-anchor="middle">'+esc(nm)+'</text>';
          s += '<text x="'+p.x+'" y="'+(p.y+9)+'" font-size="9.5" font-weight="800" fill="#f5a800" text-anchor="middle">'+p.c+'</text>';
        } else {
          s += '<text x="'+p.x+'" y="'+(p.y-r-3)+'" font-size="8.5" font-weight="700" fill="#4b1a60" text-anchor="middle">'+esc(nm)+' · '+p.c+'</text>';
        }
      });
      elM.innerHTML = s;
    }

    const elR = opts.svgRS ? document.getElementById(opts.svgRS) : null;
    const porCid = {};
    fora.forEach(i=>{ (porCid[i.cidade]=porCid[i.cidade]||[]).push(i.nome); });
    if(elR){
      let r = '<path d="'+RS_PATH+'" fill="#f0e9f6" stroke="#c9aede" stroke-width="1"/>';
      Object.keys(porCid).forEach(cid=>{
        const p = CIDADES_RS[normC(cid)];
        if(p) r += '<line x1="'+p[0]+'" y1="'+p[1]+'" x2="'+SM_RS[0]+'" y2="'+SM_RS[1]+'" stroke="#f5a800" stroke-width="1.6"/>';
      });
      Object.keys(porCid).forEach(cid=>{
        const p = CIDADES_RS[normC(cid)];
        if(p){
          r += '<circle cx="'+p[0]+'" cy="'+p[1]+'" r="4" fill="#f5a800"/>';
          const anc = p[0] > SM_RS[0]-10 ? 'start' : 'middle';
          r += '<text x="'+(p[0]+(anc==='start'?7:0))+'" y="'+(p[1]+(anc==='start'?3:13))+'" font-size="8.5" font-weight="700" fill="#854F0B" text-anchor="'+anc+'">'+esc(p[2])+'</text>';
        }
      });
      r += '<circle cx="'+SM_RS[0]+'" cy="'+SM_RS[1]+'" r="6.5" fill="#662382"/>';
      r += '<text x="'+SM_RS[0]+'" y="'+(SM_RS[1]-9)+'" font-size="9.5" font-weight="800" fill="#4b1a60" text-anchor="middle">Santa Maria</text>';
      elR.innerHTML = r;
    }

    const nBairros = Object.keys(counts).length;
    const cidades = Object.keys(porCid);
    if(opts.notaEl){
      const el = document.getElementById(opts.notaEl);
      if(el){
        const listaFora = Object.entries(porCid).map(([cid,nomes])=>esc(nomes.join(', '))+' ('+esc(cid)+')').join(' · ');
        el.innerHTML = '<b>'+xis.length+' operações de Xis inscritas</b> · '+nBairros+' bairros de Santa Maria representados'
          + (regiao.length?' · '+regiao.length+' da região':'')
          + (indef.length?' · '+indef.length+' a classificar':'')
          + (fora.length?'<br>🚚 <b>De outras cidades:</b> '+listaFora:'');
      }
    }
    if(opts.kpis) opts.kpis(xis.length, nBairros, cidades.length);
    return {total:xis.length, bairros:nBairros, cidades:cidades.length};
  };
})();
