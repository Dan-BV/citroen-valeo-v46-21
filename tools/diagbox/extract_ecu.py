"""Extract the complete diagnostic model of one ECU from a Diagbox install.

Usage:
    python extract_ecu.py --ecu V46_21 --out ../../data/diagbox

Produces one JSON per ECU containing: CAN addressing, every diagnostic
service with its full request/response byte map (position, length, factor,
offset, unit, enumerated states), the DTC list, actuator tests, telecoding
parameters and the Lexia measurement screens.

The Diagbox databases are opened read-only from copies made by prepare.py,
so the installation itself is never touched.
"""
import argparse
import copy
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dbxlib import Thesaurus, connect, rows  # noqa: E402


def clean(v):
    return v if v not in ('', None) else None


def f32(v):
    """Diagbox stores factors/offsets as float32; drop the binary noise."""
    if v is None:
        return None
    return float('%.7g' % v)


class Extractor:
    def __init__(self, workdir, fbdir, transdir, langs):
        self.gpc = connect(fbdir, os.path.join(workdir, 'GPC.FDB'))
        self.dsd = connect(fbdir, os.path.join(workdir, 'DSD.FDB'))
        self.th = {l: Thesaurus(transdir, l) for l in langs}
        self.primary = langs[0]

    def label(self, ref):
        """Return {lang: text} for a thesaurus reference, primary lang first."""
        if not ref:
            return None
        out = {}
        for lang, th in self.th.items():
            t = th.resolve(ref)
            if t:
                out[lang] = t
        return out or None

    # ------------------------------------------------------------- topology

    def ecu_instances(self, name):
        sql = """
        select e.ECUID, e.FAMID, e.ECUCODE, e.ECUNBRDTC, e.ECUEDOFILENAME,
               e.I_ECUGRPDTCID, e.ECUP2TIMEOUT, e.ECUP3TIMEOUT, e.ECUSTMIN,
               t.ECUTYID, t.ECUNAME, t.ECULIBNAME, t.ECUSERVICELAYER,
               t.ECUTMOUT, t.ECUREVEIL, t.ECUTYPEINIT,
               f.FAMIDCANR, f.FAMIDCANE, f.FAMCANBUS, f.FAMCANLINE,
               f.FAMCANADDRESSTYPE, f.FAMCANIDTYPE, f.FAMCANPADDING,
               f.FAMCODETARGET, f.FAMSOURCECODE, f.FAMNETWORK,
               ft.FAMNAME, v.VEHCOMTYPE,
               p.PROTID, pt.PROTNAME
        from ECU e
        join ECUTYPE t on t.ECUTYID = e.ECUTYID
        join FAMILY f on f.FAMID = e.FAMID
        join FAMTYPE ft on ft.FAMTYID = f.FAMTYID
        join VEHICULE v on v.VEHID = f.VEHID
        left join PROTOCOL p on p.PROTID = t.PROTID
        left join PROTTYPE pt on pt.PROTTYID = p.PROTTYID
        where t.ECUNAME = ? and t.ECUCOMMENT <> 'ecu telechargement'
        order by v.VEHCOMTYPE
        """
        return list(rows(self.gpc, sql, name))

    # -------------------------------------------------------- GPC parameters

    def gpc_params(self, ecuid):
        """Per-ECU parameter metadata keyed by parameter name."""
        sql = """
        select p.PARID, p.PARNAME, p.PARLIBMP, p.PARLIBUNIT, p.PARDISC,
               p.PARVALMIN, p.PARVALMAX, p.PARFORMAT, p.PARAIDE
        from PARAM p
        where p.PARID in (select sp.PARID from I_SCRPAR sp
                          join SCREEN s on s.SCRID = sp.SCRID
                          where s.ECUID = ?)
        """
        out = {}
        for r in rows(self.gpc, sql, ecuid):
            out.setdefault(r['PARNAME'], r)
        return out

    def discrete_values(self, parids):
        """value -> label map for each PARID that has enumerated states."""
        if not parids:
            return {}
        ids = ','.join(str(int(i)) for i in parids)
        sql = """
        select ip.PARID, d.DISCNAME, d.DISCVALLIB, d.DISCVALCOM,
               d.DISCINF, d.DISCSUP, d.DISCDEFAULT
        from I_PARDIS ip join DISCVAL d on d.DISCID = ip.DISCID
        where ip.PARID in (%s)
        """ % ids
        out = {}
        for r in rows(self.gpc, sql):
            bucket = out.setdefault(r['PARID'], {})
            val = r['DISCVALCOM']
            key = 'default' if val is None else str(int(val))
            if key not in bucket:
                bucket[key] = {
                    'raw': None if val is None else int(val),
                    'name': r['DISCNAME'],
                    'label': self.label(r['DISCVALLIB']),
                    'is_invalid': bool(r['DISCDEFAULT']),
                }
        return out

    # -------------------------------------------------------- DSD byte maps

    def dsd_ecuver(self, name):
        return list(rows(self.dsd, """
            select ECUVEID, ECUVEECUNAME, ECUVEMNEMONAME, ECUVEFILENAME,
                   ECUVEDEFMODE
            from ECUVER where ECUVEECUNAME = ? order by ECUVEID""", name))

    def services(self, ecuveid):
        svc = list(rows(self.dsd, """
            select s.SERID, s.SERSNAME, s.SERLNAME, s.SERDESCRIPTION
            from I_ECUSER e join SERVICE s on s.SERID = e.SERID
            where e.ECUVEID = ? order by s.SERSNAME""", ecuveid))
        for s in svc:
            s['units'] = self.service_units(s['SERID'])
        return svc

    def service_units(self, serid):
        units = list(rows(self.dsd, """
            select SERUNID, SERUNSNAME, SERUNTYPE, SERUNDESCRIPTION,
                   SERUNFRAMETYPE, SERUNSECURED
            from SERVUNIT where SERID = ? order by SERUNSNAME""", serid))
        for u in units:
            u['frames'] = {}
            for f in rows(self.dsd, """
                select f.SERUNFRID, t.SERUNFRTYNAME, f.SERUNFRDESCRIPTION
                from SERVUNITFRAME f
                join SERVUNITFRAMETYPE t on t.SERUNFRTYID = f.SERUNFRTYID
                where f.SERUNID = ?""", u['SERUNID']):
                u['frames'][f['SERUNFRTYNAME']] = self.frame_bytes(
                    f['SERUNFRID'])
            self.split_dynamic(u)
        return units

    def split_dynamic(self, unit):
        """Move dynamic-block bytes out of the flat frame into named groups.

        Page $87 (freeze frame) answers with a layout chosen by the DTC code
        in the request. Inside a group ISPBYTEPOS restarts at 1, relative to
        the block start, so absolute position = block_start + pos - 1.
        """
        for fname, frame in list(unit['frames'].items()):
            dyn = [b for b in frame if b.get('dyn_id')]
            if not dyn:
                continue
            unit['frames'][fname] = [b for b in frame if not b.get('dyn_id')]
            groups, key, starts = {}, None, {}
            for b in dyn:
                gname = b.get('dyn_group') or b.get('dyn_name') or 'default'
                key = key or b.get('dyn_key')
                starts[gname] = b.get('dyn_byte_pos') or 1
                if b['role'] == 'DYNAMICBLOCK' or b['name'] is None:
                    continue        # block anchor, carries no data itself
                b['byte_pos'] = starts[gname] + b['byte_pos'] - 1
                groups.setdefault(gname, []).append(b)
            for g in groups.values():
                g.sort(key=lambda x: (x['byte_pos'], x['name'] or ''))
                for b in g:
                    for k in ('dyn_group', 'dyn_key', 'dyn_byte_pos',
                              'dyn_id', 'dyn_name'):
                        b.pop(k, None)
            if len(groups) == 1:
                # A single layout is not really dynamic: fold it back in.
                only = next(iter(groups.values()))
                unit['frames'][fname] = sorted(
                    unit['frames'][fname] + only,
                    key=lambda x: (x['byte_pos'], x['name'] or ''))
                continue
            unit.setdefault('dynamic', {})[fname] = {
                'key': key,
                'block_start': min(starts.values()),
                'groups': groups,
                'group_members': self.dyn_group_members(unit),
            }

    def dyn_group_members(self, unit):
        """Which key values (DTC codes) select which dynamic group."""
        req = unit['frames'].get('REQUEST') or []
        keys = [b['parid'] for b in req if b.get('parid') and b['name']
                not in ('SID', 'LID')]
        out = {}
        for parid in keys:
            for r in rows(self.dsd, """
                select STAGROUPNAME, STAVALUE from STATES
                where PARID = ? and STAGROUPNAME is not null""", parid):
                out.setdefault(r['STAGROUPNAME'], []).append(r['STAVALUE'])
        return out or None

    def frame_bytes(self, serunfrid):
        sql = """
        select sp.ISPBYTEPOS, sp.ISPVALUE, sp.ISPNUMBER, sp.ISPDESCRIPTION,
               sp.ISPSECURED, sp.ISPLEVEL, pt.PARTYNAME,
               dy.DYNID, dy.DYNSNAME, dy.DYNKEYNAME, dy.DYNVALUEGROUP,
               dy.DYNBYTEPOS,
               p.PARID, p.PARSNAME, p.PARLNAME, p.PARDESCRIPTION,
               p.PARENCODING, p.PARBASEENCODING, dt.DATTYNAME,
               a.ADDBYTELENGTH, a.ADDBYTEORDER, a.ADDBITLENGTH,
               a.ADDBITMASK, a.ADDMINLENGTH, a.ADDMAXLENGTH,
               c.CONFORMULA, c.CONFACTOR, c.CONOFFSET, c.CONUNIT,
               ct.CONTYNAME, b.BLOSNAME, b.BLOBYTELENGTH
        from I_SERPAR sp
        left join PARAM p on p.PARID = sp.PARID
        left join PARTYPE pt on pt.PARTYID = sp.PARTYID
        left join DATATYPE dt on dt.DATTYID = p.DATTYID
        left join ADDDATA a on a.PARID = p.PARID
        left join CONVFORM c on c.PARID = p.PARID
        left join CONFORMTYPE ct on ct.CONTYID = c.CONTYID
        left join BLOCK b on b.BLOID = sp.BLOID
        left join DYNAMICBLOCK dy on dy.DYNID = sp.DYNID
        where sp.SERUNFRID = ?
        order by sp.ISPBYTEPOS
        """
        out = []
        for r in rows(self.dsd, sql, serunfrid):
            out.append({
                'byte_pos': r['ISPBYTEPOS'],
                'name': r['PARSNAME'],
                'desc': clean(r['PARLNAME']) or clean(r['PARDESCRIPTION']),
                'role': r['PARTYNAME'],
                'const_hex': clean(r['ISPVALUE']),
                'data_type': r['DATTYNAME'],
                'encoding': r['PARBASEENCODING'],
                'byte_len': r['ADDBYTELENGTH'],
                'bit_len': r['ADDBITLENGTH'],
                'bit_mask': clean(r['ADDBITMASK']),
                'byte_order_raw': r['ADDBYTEORDER'],
                'conv': r['CONTYNAME'],
                'factor': f32(r['CONFACTOR']),
                'offset': f32(r['CONOFFSET']),
                'formula': clean(r['CONFORMULA']),
                'block': clean(r['BLOSNAME']),
                'dyn_group': clean(r['DYNVALUEGROUP']),
                'dyn_key': clean(r['DYNKEYNAME']),
                'dyn_byte_pos': r['DYNBYTEPOS'],
                'dyn_id': r['DYNID'],
                'dyn_name': clean(r['DYNSNAME']),
                'parid': r['PARID'],
            })
        return out

    # -------------------------------------------------------------- merging

    def name_index(self, ecuid):
        """name -> {label, unit, states, min, max, format} for one ECU."""
        idx = {}
        items = list(rows(self.gpc, """
            select distinct p.PARID, p.PARNAME, p.PARLIBMP, p.PARLIBUNIT,
                   p.PARVALMIN, p.PARVALMAX, p.PARFORMAT, p.PARDISC
            from I_SCRPAR sp
            join SCREEN s on s.SCRID = sp.SCRID
            join PARAM p on p.PARID = sp.PARID
            where s.ECUID = ?""", ecuid))
        # Configuration parameters live on telecoding screens, not measurement
        # screens, but the write frames reference them by the same name.
        items += list(rows(self.gpc, """
            select distinct p.PARID, p.PARNAME, p.PARLIBMP, p.PARLIBUNIT,
                   p.PARVALMIN, p.PARVALMAX, p.PARFORMAT, p.PARDISC
            from I_TPMSCRPAR sp
            join TPMSCREEN t on t.TPMSCRID = sp.TPMSCRID
            join PARAM p on p.PARID = sp.PARID
            where t.ECUID = ?""", ecuid))
        disc = self.discrete_values([i['PARID'] for i in items])
        for i in items:
            if i['PARNAME'] in idx:
                continue
            idx[i['PARNAME']] = {
                'label': self.label(i['PARLIBMP']),
                'unit': self.label(i['PARLIBUNIT']),
                'min': i['PARVALMIN'], 'max': i['PARVALMAX'],
                'format': i['PARFORMAT'],
                'states': list(disc.get(i['PARID'], {}).values()) or None,
            }
        return idx

    @staticmethod
    def alias(name, idx):
        """Map read-back configuration names onto their write counterparts.

        The $A0 read frame names an option `UCPO_ESP` / `FPO`, while the write
        frame and the telecoding screens call the same option
        `CFG_000_CMM_UCPR_ESP` / `CFG_000_CMM_FPR`. The sets match one to one,
        so reuse the label. Generation suffixes (`_009`, `_010`) are dropped
        when the plain name is known.
        """
        cands = []
        if name.startswith('UCPO_'):
            cands.append('CFG_000_CMM_UCPR_' + name[5:])
        elif name.endswith('PO'):
            cands.append('CFG_000_CMM_' + name[:-2] + 'PR')
        base = name.rsplit('_', 1)
        if len(base) == 2 and base[1].isdigit():
            cands.append(base[0])
        for c in cands:
            if c in idx:
                return idx[c]
        return None

    @staticmethod
    def enrich(services, idx):
        """Attach human labels / units / enum states to every frame byte."""
        for svc in services:
            for unit in svc['units']:
                frames = list(unit['frames'].values())
                for dyn in (unit.get('dynamic') or {}).values():
                    frames.extend(dyn['groups'].values())
                for frame in frames:
                    for b in frame:
                        b.pop('parid', None)
                        if not b['name']:
                            continue
                        meta = idx.get(b['name']) or Extractor.alias(
                            b['name'], idx)
                        if not meta:
                            continue
                        b['label'] = meta['label']
                        b['unit'] = meta['unit']
                        b['format'] = meta['format']
                        if meta['min'] is not None:
                            b['min'] = meta['min']
                        if meta['max'] is not None:
                            b['max'] = meta['max']
                        if meta['states']:
                            b['states'] = meta['states']

    # --------------------------------------------------------------- extras

    def dtcs(self, grpid):
        sql = """
        select d.DTCID, d.DTCCODE, d.DTCNAME, d.DTCLABEL, d.DTCDESCRIPTION
        from I_ECUDTC ie join DTC d on d.DTCID = ie.DTCID
        where ie.I_ECUGRPDTCID = ? order by d.DTCCODE
        """
        out = []
        for r in rows(self.gpc, sql, grpid):
            props = [{
                'name': p['PRONAME'], 'kind': p['PROTYPE'],
                'dsd_name': p['PRODSDNAME'], 'label': self.label(p['PROLABEL']),
            } for p in rows(self.gpc, """
                select pr.PRONAME, pr.PROTYPE, pr.PRODSDNAME, pr.PROLABEL
                from I_DTCPRO dp join DTCPROPERTY pr on pr.PROID = dp.PROID
                where dp.DTCID = ?""", r['DTCID'])]
            out.append({
                'code': r['DTCCODE'],
                'name': clean(r['DTCNAME']),
                'label': self.label(r['DTCLABEL']),
                'description': self.label(r['DTCDESCRIPTION']),
                'properties': props,
            })
        return out

    def actuator_tests(self, ecuid):
        sql = """
        select t.TAMID, t.TAMNAME, t.TITLE, t.TAMTYPE, t.TAMHELPTEXT,
               t.STARTBYUSER, t.STOPBYUSER,
               c.TAMCTRLID, c.CTRLNAME, c.CTRLTYPE, c.MAXDURATION,
               c.MINTIMEBEFORERESTART, c.CTRLSTATUSPARNAME,
               c.CTRLSTATUSPARLABEL, c.SENDSTATUSREQUEST
        from I_ECUTAM i join TAM t on t.TAMID = i.TAMID
        left join TAMCTRL c on c.TAMCTRLID = i.TAMCTRLID
        where i.ECUID = ? order by t.TAMNAME
        """
        out = []
        for r in rows(self.gpc, sql, ecuid):
            servs = []
            if r['TAMCTRLID'] is not None:
                for s in rows(self.gpc, """
                    select v.TAMSERVID, v.SERVNAME, v.SERVROLE, v.SERVICE,
                           v.SUBSERVICE
                    from I_CTRLSERV cs join TAMSERV v
                      on v.TAMSERVID = cs.TAMSERVID
                    where cs.TAMCTRLID = ?""", r['TAMCTRLID']):
                    # Fixed request bytes are encoded in the value name as
                    # <PARAM>_<HEX>, e.g. NSP_51 -> actuator id 0x51.
                    args = {}
                    for p in rows(self.gpc, """
                        select tp.PARNAME, tp.PARTYPE, sp.ISERVPARVALUE
                        from I_SERVPAR sp join TAMPARAM tp
                          on tp.TAMPARAMID = sp.TAMPARAMID
                        where sp.TAMSERVID = ?""", s['TAMSERVID']):
                        val = p['ISERVPARVALUE'] or ''
                        pre = p['PARNAME'] + '_'
                        args[p['PARNAME']] = (val[len(pre):]
                                              if val.startswith(pre) else val)
                    servs.append({
                        'role': s['SERVROLE'], 'name': s['SERVNAME'],
                        'service': s['SERVICE'], 'unit': s['SUBSERVICE'],
                        'args': args or None,
                    })
            out.append({
                'name': r['TAMNAME'],
                'title': self.label(r['TITLE']),
                'type': r['TAMTYPE'],
                'control': clean(r['CTRLNAME']),
                'control_type': clean(r['CTRLTYPE']),
                'max_duration_ms': r['MAXDURATION'],
                'status_param': clean(r['CTRLSTATUSPARNAME']),
                'status_label': self.label(r['CTRLSTATUSPARLABEL']),
                'services': servs,
            })
        return out

    def telecoding(self, ecuid):
        sql = """
        select ts.TPMSCRID, ts.TPMSCRNAME, ts.TPMSCRREADTITLE,
               ts.TPMSCRWRITETITLE
        from TPMSCREEN ts where ts.ECUID = ? order by ts.TPMSCRNAME
        """
        out = []
        for s in rows(self.gpc, sql, ecuid):
            params = []
            for p in rows(self.gpc, """
                select sp.PARID, p.PARNAME, p.PARLIBMP, p.PARLIBUNIT,
                       p.PARVALMIN, p.PARVALMAX, p.PARFORMAT,
                       sp.READSERVICE, sp.READSERVICEUNIT,
                       sp.WRITESERVICE, sp.WRITESERVICEUNIT,
                       tp.PARTPMCLASS, tp.PARTPMTYPE, tp.PARTPMMODE,
                       tp.PARTPMSECURED, tp.PARTPMIMPOSEDVALUE,
                       tp.PARTPMREADNAME, tp.PARTPMORDER
                from I_TPMSCRPAR sp
                join PARAM p on p.PARID = sp.PARID
                left join I_PARAMTPM ipt on ipt.PARID = sp.PARID
                left join PARAMTPM tp on tp.PARTPMID = ipt.PARTPMID
                where sp.TPMSCRID = ?""", s['TPMSCRID']):
                params.append({
                    'parid': p['PARID'],
                    'name': p['PARNAME'],
                    'label': self.label(p['PARLIBMP']),
                    'unit': self.label(p['PARLIBUNIT']),
                    'min': p['PARVALMIN'], 'max': p['PARVALMAX'],
                    'format': p['PARFORMAT'],
                    'read': [p['READSERVICE'], p['READSERVICEUNIT']],
                    'write': [p['WRITESERVICE'], p['WRITESERVICEUNIT']],
                    'class': clean(p['PARTPMCLASS']),
                    'kind': clean(p['PARTPMTYPE']),
                    'mode': clean(p['PARTPMMODE']),
                    'secured': p['PARTPMSECURED'],
                })
            disc = self.discrete_values([p['parid'] for p in params])
            for p in params:
                p['states'] = list(disc.get(p['parid'], {}).values()) or None
                p.pop('parid')
            out.append({
                'screen': s['TPMSCRNAME'],
                'read_title': self.label(s['TPMSCRREADTITLE']),
                'write_title': self.label(s['TPMSCRWRITETITLE']),
                'params': params,
            })
        return out

    def screens(self, ecuid):
        out = []
        for s in rows(self.gpc, """
            select SCRID, SCRNAME, SCRTITRE, SCRREFRESH
            from SCREEN where ECUID = ? order by SCRNAME""", ecuid):
            items = list(rows(self.gpc, """
                select sp.PARPOS, sp.REFRESHRATE, p.PARID, p.PARNAME,
                       p.PARLIBMP, p.PARLIBUNIT, p.PARVALMIN, p.PARVALMAX,
                       p.PARFORMAT, p.PARDISC
                from I_SCRPAR sp join PARAM p on p.PARID = sp.PARID
                where sp.SCRID = ? order by sp.PARPOS""", s['SCRID']))
            disc = self.discrete_values([i['PARID'] for i in items])
            out.append({
                'screen': s['SCRNAME'],
                'title': self.label(s['SCRTITRE']),
                'params': [{
                    'pos': i['PARPOS'],
                    'name': i['PARNAME'],
                    'label': self.label(i['PARLIBMP']),
                    'unit': self.label(i['PARLIBUNIT']),
                    'min': i['PARVALMIN'], 'max': i['PARVALMAX'],
                    'format': i['PARFORMAT'],
                    'discrete': bool(i['PARDISC']),
                    'states': list(disc.get(i['PARID'], {}).values()) or None,
                } for i in items],
            })
        return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ecu', required=True)
    ap.add_argument('--work', required=True, help='dir with the FDB copies')
    ap.add_argument('--fbdir', required=True, help='dir with fbembed.dll')
    ap.add_argument('--trans', required=True, help='Diagbox dtrd/trans dir')
    ap.add_argument('--langs', default='en_GB,ru_RU')
    ap.add_argument('--out', required=True)
    a = ap.parse_args()

    langs = [x for x in a.langs.split(',') if x]
    ex = Extractor(a.work, a.fbdir, a.trans, langs)

    instances = ex.ecu_instances(a.ecu)
    if not instances:
        sys.exit('ECU %r not found' % a.ecu)

    vers = ex.dsd_ecuver(a.ecu)
    services = ex.services(vers[0]['ECUVEID']) if vers else []

    doc = {
        'ecu': a.ecu,
        'source': 'Diagbox GPC.FDB + DSD.FDB + POLUXDATA dictionaries',
        'languages': langs,
        'comm_library': instances[0]['ECULIBNAME'],
        'service_layer': instances[0]['ECUSERVICELAYER'],
        'protocol': instances[0]['PROTNAME'],
        'can': {
            'request_id': instances[0]['FAMIDCANE'],
            'response_id': instances[0]['FAMIDCANR'],
            'bus': instances[0]['FAMCANBUS'],
            'line': instances[0]['FAMCANLINE'],
            'target_code': instances[0]['FAMCODETARGET'],
        },
        'variants': [{
            'platform': i['VEHCOMTYPE'],
            'ecuid': i['ECUID'],
            'odx_file': i['ECUEDOFILENAME'],
            'dtc_count': i['ECUNBRDTC'],
            'p2_timeout_ms': i['ECUP2TIMEOUT'],
            'p3_timeout_ms': i['ECUP3TIMEOUT'],
            'st_min_ms': i['ECUSTMIN'],
            'can_request_id': i['FAMIDCANE'],
            'can_response_id': i['FAMIDCANR'],
        } for i in instances],
        'dsd_versions': [{
            'mnemonic': v['ECUVEMNEMONAME'], 'odx': v['ECUVEFILENAME'],
            'is_default': bool(v['ECUVEDEFMODE']),
        } for v in vers],
        'services': services,
    }

    os.makedirs(a.out, exist_ok=True)
    for inst in instances:
        plat = inst['VEHCOMTYPE']
        per = dict(doc)
        per['platform'] = plat
        per['services'] = copy.deepcopy(services)
        ex.enrich(per['services'], ex.name_index(inst['ECUID']))
        per['dtcs'] = ex.dtcs(inst['I_ECUGRPDTCID'])
        per['actuator_tests'] = ex.actuator_tests(inst['ECUID'])
        per['telecoding'] = ex.telecoding(inst['ECUID'])
        per['screens'] = ex.screens(inst['ECUID'])
        path = os.path.join(a.out, '%s_%s.json' % (a.ecu, plat))
        with open(path, 'w', encoding='utf-8') as fh:
            json.dump(per, fh, ensure_ascii=False, indent=1)
        print('%-28s %5d dtc  %3d tests  %3d screens  -> %s'
              % (plat, len(per['dtcs']), len(per['actuator_tests']),
                 len(per['screens']), os.path.basename(path)))


if __name__ == '__main__':
    main()
