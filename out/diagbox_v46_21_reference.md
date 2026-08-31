# Valeo V46.21 engine ECU - diagnostic reference

Extracted from a Diagbox 9.85 installation (`GPC.FDB`, `DSD.FDB` and the `POLUXDATA` string dictionaries). This is the same model the Lexia/Diagbox application itself drives, so the frames below are what the official tool sends.

- ECU: **V46_21**, platform **B7**
- Transport: **DIAGONCAN** (KWP2000 on ISO 15765-2)
- CAN request id **0x6A8**, response id **0x688**, 11-bit, 500 kbit/s
- Diagbox communication library: `Cal458.dll`

Timing: not overridden in the database, so the ISO 15765-2 defaults apply.

This ECU is defined for 11 PSA platforms (A9, B6, B7, B9, E3, K9, LA, M3_M4, P2, T7, T9); they share one ODX definition (`V46_21_V1.xml`), so the frames are identical. Only the fault-code list differs slightly.

## Verified against a live capture

The map below is not a guess. `tools/diagbox/decode.py` replays the ELM transcript recorded from this car on 2026-08-27 through it; every page decodes to physically sensible values on a cold engine at fast idle:

| Page | Field | Decoded |
|---|---|---|
| $80 | Equipment part number | 9804436280 (Valeo) |
| $FE | Software edition | 0E18, 2 downloads |
| $C0 | Upstream oxygen sensor | 766 mV, rich, closed loop |
| $C0 | Injection time, all four cylinders | 5.0 ms |
| $C1 | Optimum / applied ignition advance | 19 deg / -7 deg |
| $C2 | Air flow, manifold pressure | 19.8 kg/h, 441 mBar |
| $C2 | Cam phaser reference / actual | 28 deg / 29 deg |
| $C2 | Engine start counter | 19425 |
| $CA | Fuel level, vehicle speed | 14 litre, 0 kph |
| $CA | Coolant temperature at last stop | 95 deg C |
| $CB | Sensor supply voltages 1/2/3 | 5000 / 4990 / 4980 mV |
| $CB | Engine speed, ECU supply | 1103 rpm, 14.3 V |

Two things this settles for anyone who reverse-engineered these pages by hand: coolant temperature on the live pages is `raw - 50`, not the usual `raw - 40`, and the `80 01` suffix does not change the byte layout - a bare `21 CB` answers `61 CB ...` with the payload at the same positions as `61 FF ...`.

## Byte order

`ADDDATA.ADDBYTEORDER` in the database reads `LittleEndian` for the multi-byte fields of this ECU, but on the wire the **most significant byte comes first**. Verified against live captures: engine speed `04 4F` = 1103 rpm and sensor supply `01 F4` x 10 = 5000 mV. Decode multi-byte integers MSB-first.

## Session sequence

```
ATSP6            ; ISO 15765-4, 11 bit, 500k
ATSH6A8           ; request header
ATCRA688          ; accept only the ECU answer
ATFCSH6A8  ATFCSD300000  ATFCSM1
ATAL             ; allow long (multi-frame) messages
81               ; StartCommunication  -> C1 D0 8F
...              ; diagnostic requests
3E               ; TesterPresent, keep the session alive
82               ; StopCommunication   -> C2
```

`81` is mandatory: the proprietary `21 xx` pages answer `7F 21 ..` until the session is started. There is no need for `10 C0` / `10 03`; this ECU answers `7F 10 12` (subfunction not supported) to those.

## Service catalogue

| Service | SID | Units | Purpose |
|---|---|---:|---|
| `CLRDI` | `14` | 1 | ClearDiagnosticInformation |
| `ECURESET` | `11` | 14 | ECURESET |
| `IOCBLID` | `30` | 1 | InputOutputControlByLocalID |
| `IOCBLIDAR` | `30` | 1 | InputOutputControlByLocalID |
| `IOCBLIDST` | `30` | 1 | InputOutputControlByLocalID |
| `RDBLID` | `21` | 16 | Readdatabylocalidentifier |
| `RDSDTC` | `17` | 1 | ReadStatusOfDiagnosticTroubleCodes |
| `REQDWN` | `34` | 13 | Request Download |
| `SA` | `27` | 2 | Security Access |
| `SC` | `81` | 1 | StartCommunication |
| `SP` | `82` | 1 | StopCommunication |
| `SRBLID` | `32` | 11 | SRBLID |
| `TP` | `3E` | 1 | TesterPresent |

## Live measurement pages

Every page is requested as `21 <LID> 80 01` and answered as `61 FF <data>`. The trailing `80 01` asks the ECU for the full record; the answer identifier is `FF` rather than the page id, so a reader must track which page it asked for. Byte 1 of the tables below is the `61`, byte 2 the `FF`, so payload starts at byte 3.

### $B0 - Electrical supplies and immobiliser

Request `21 B0 8001` -> `61 FF ...` (4 fields)

| Byte | Len | Mask | Parameter | Meaning | Decode | Unit | States |
|---:|---:|---|---|---|---|---|---|
| 3 | 1 |  | `MP_ETAT_VERROUILLAGE_DEVERROUILLAGE_CALCULTATEUR` | control unit condition | enum |  | 0=ECU not locked, 1=ECU locked |
| 4 | 1 |  | `MP_ETAT_PROGRAMMATION_ANTI_DEMARRAGE` | status of the coded engine immobiliser programming | enum |  | 255=Study status, 0=After-sales status, 1=programmed 1 times, 2=programmed 2 times, 3=programmed 3 times, 4=ECU matched, normal locking |
| 5 | 1 |  | `MP_PB_TRANSMISSION_CODE_DEVERROUILLAGE` | problems detected during transmission of the unlocking code | enum |  | 0=no problem found, 1=Awaiting response from BSI, 2=response from the built-in systems interface incorrect, 4=reading of the coded immobiliser code impossible, 8=the coded immobiliser programming status cannot be read |
| 6 | 1 |  | `MP_OPTION_APPAIRAGE_CHOISIE` | Matching option selected | enum |  | 0=Automatic pairing, 1=Pairing by request |

### $C0 - Mixture and fuelling

Request `21 C0 8001` -> `61 FF ...` (20 fields)

| Byte | Len | Mask | Parameter | Meaning | Decode | Unit | States |
|---:|---:|---|---|---|---|---|---|
| 3 | 2 |  | `MP_REGIME_MOTEUR` | Engine speed | raw | Rpm |  |
| 5 | 1 |  | `MP_TENSION_ALIMENTATION_CALCULATEUR_CONTROLE_MOTEUR` | Engine management ECU supply voltage | raw x 0.1 | V |  |
| 6 | 1 |  | `MP_TEMPERATURE_D_EAU_MOTEUR_d` | engine coolant temperature | raw -50 | deg. C |  |
| 7 | 2 |  | `MP_TEMPS_INJECTION_CYLINDRE_01` | cylinder 1 injection time | raw x 0.01 | ms |  |
| 9 | 2 |  | `MP_TEMPS_INJECTION_CYLINDRE_02` | cylinder 2 injection time | raw x 0.01 | ms |  |
| 11 | 2 |  | `MP_TEMPS_INJECTION_CYLINDRE_03` | cylinder 3 injection time | raw x 0.01 | ms |  |
| 13 | 2 |  | `MP_TEMPS_INJECTION_CYLINDRE_04` | cylinder 4 injection time | raw x 0.01 | ms |  |
| 23 | 1 |  | `MP_ETAT_SONDE_A_OXYGENE_AMONT` | upstream oxygen sensor status | enum |  | 0=weak, 1=rich |
| 25 | 1 |  | `MP_ETAT_REGULATION_SONDE_A_OXYGENE_AMONT` | upstream oxygen sensor regulation status | enum |  | 0=open loop, 1=closed loop |
| 27 | 2 |  | `MP_TENSION_SONDE_A_OXYGENE_AMONT` | upstream oxygen sensor voltage | raw | mv |  |
| 31 | 1 |  | `MP_ETAT_SONDE_A_OXYGENE_AVAL` | downstream oxygen sensor status | enum |  | 0=weak, 1=rich |
| 33 | 1 |  | `MP_ETAT_REGULATION_SONDE_A_OXYGENE_AVAL` | downstream oxygen sensor regulation status | enum |  | 0=open loop, 1=closed loop |
| 35 | 2 |  | `MP_TENSION_SONDE_A_OXYGENE_AVAL` | downstream oxygen sensor voltage | raw | mv |  |
| 39 | 2 |  | `MP_RCOAMONT` | upstream sensor heating OCR control | raw x 0.1 | % |  |
| 43 | 2 |  | `MP_RCOAVAL` | Opening cyclic ratio of the downstream oxygen sensor heating | raw x 0.1 | % |  |
| 47 | 2 |  | `MP_FACTEUR_CORRECTION_RICHESSE_AMONT` | upstream mixture correction factor | raw x 7.63e-06 -0.25 |  |  |
| 51 | 2 |  | `MP_FACTEUR_CORRECTION_RICHESSE_AVAL` | downstream mixture correction factor | raw x 7.63e-06 -0.25 |  |  |
| 55 | 1 |  | `MP_CHARGE_ESTIMEE_CANISTER` | estimated canister load | raw | % |  |
| 56 | 2 |  | `MP_CON_RICHESSE` | Richness reference | raw x 0.001 |  |  |
| 58 | 1 |  | `MP_CDERCOELECPURGE` | canister discharge electrovalve open cycle ratio | raw | % |  |

### $C1 - Ignition

Request `21 C1 8001` -> `61 FF ...` (11 fields)

| Byte | Len | Mask | Parameter | Meaning | Decode | Unit | States |
|---:|---:|---|---|---|---|---|---|
| 3 | 2 |  | `MP_REGIME_MOTEUR` | Engine speed | raw | Rpm |  |
| 5 | 1 |  | `MP_TENSION_ALIMENTATION_CALCULATEUR_CONTROLE_MOTEUR` | Engine management ECU supply voltage | raw x 0.1 | V |  |
| 6 | 1 |  | `MP_TEMPERATURE_D_EAU_MOTEUR_d` | engine coolant temperature | raw -50 | deg. C |  |
| 7 | 1 |  | `MP_AVANCE_ALLUMAGE_OPTIMAL` | optimum ignition advance | raw -100 | ° crankshaft |  |
| 8 | 1 |  | `MP_AVANCE_ALLUMAGE_MAXIMUM` | maximum ignition advance | raw -100 | ° crankshaft |  |
| 9 | 1 |  | `MP_AVANCE_ALLUMAGE_MINIMUM` | minimum ignition advance | raw -100 | ° crankshaft |  |
| 10 | 1 |  | `MP_AVANCE_ALLUMAGE_APPLIQUEE_A_CHAQUE_CYLINDRE` | Ignition advance applied to each cylinder | raw -100 | ° crankshaft |  |
| 16 | 1 |  | `MP_RETRAIT_AVANCE_ALLUMAGE_CYLINDRE_01` | cylinder 1 advance reduction | raw -100 | ° crankshaft |  |
| 17 | 1 |  | `MP_RETRAIT_AVANCE_ALLUMAGE_CYLINDRE_02` | cylinder 2 advance reduction | raw -100 | ° crankshaft |  |
| 18 | 1 |  | `MP_RETRAIT_AVANCE_ALLUMAGE_CYLINDRE_03` | cylinder 3 advance reduction | raw -100 | ° crankshaft |  |
| 19 | 1 |  | `MP_RETRAIT_AVANCE_ALLUMAGE_CYLINDRE_04` | cylinder 4 advance reduction | raw -100 | ° crankshaft |  |

### $C2 - Intake circuit

Request `21 C2 8001` -> `61 FF ...` (20 fields)

| Byte | Len | Mask | Parameter | Meaning | Decode | Unit | States |
|---:|---:|---|---|---|---|---|---|
| 3 | 2 |  | `MP_REGIME_MOTEUR` | Engine speed | raw | Rpm |  |
| 5 | 1 |  | `MP_TENSION_ALIMENTATION_CALCULATEUR_CONTROLE_MOTEUR` | Engine management ECU supply voltage | raw x 0.1 | V |  |
| 6 | 1 |  | `MP_TEMP_AIR_ADMISSION_SUP` | Inlet air temperature | raw -50 | deg. C |  |
| 7 | 1 |  | `MP_REMPLISSAGE_DE_CONSIGNE` | reference filling | raw | % |  |
| 8 | 1 |  | `MP_REMPLISSAGE_MESURE` | measured filling | raw | % |  |
| 12 | 2 |  | `MP_DEBIT_AIR` | air flow | raw x 0.1 | kg/h |  |
| 14 | 1 |  | `MP_CONSIGNE_PRESSION_ADMISSION` | Inlet pressure reference | raw x 21 | mBar |  |
| 15 | 1 |  | `MP_PRESSIONTUBULURE` | intake air manifold pressure | raw x 21 | mBar |  |
| 16 | 1 |  | `MP_ANGLE_PAPILLON_CONSIGNE` | reference throttle angle | raw | ° |  |
| 17 | 1 |  | `MP_ANGLE_PAPILLON_MESURE` | measured throttle angle | raw | ° |  |
| 18 | 2 |  | `MP_TENSION_RECOPIE_POSITION_PAPILLON_01` | Throttle position sensor voltage copy 1 | raw x 10 | mv |  |
| 20 | 2 |  | `MP_TENSION_RECOPIE_POSITION_PAPILLON_02` | Throttle position sensor voltage copy 2 | raw x 10 | mv |  |
| 22 | 1 |  | `MP_CONSIGNE_POSITION_DEPHASEUR_AAC_ADMISSION` | inlet camshaft dephaser position reference value | raw -100 | ° crankshaft |  |
| 24 | 1 |  | `MP_POS_DEPHASEUR_ACC_1` | position of the inlet camshaft dephaser | raw -100 | ° crankshaft |  |
| 26 | 1 |  | `MP_RCO_ELECTROVANNE_DEPHASEUR_ACC_1` | Opening cyclic ratio of the inlet camshaft dephaser solenoid valve | raw | % |  |
| 27 | 1 |  | `MP_ETAT_COH_POSITION_AAC_ADMI_VIL` | status of the coherence between the inlet camshaft and crankshaft positions | enum |  | 0=positions not coherent, 1=positions coherent |
| 31 | 2 |  | `MP_COMPTDEMMOT` | Counter of the number of times the engine has been started | raw |  |  |
| 52 | 2 |  | `MP_DEBAIRCONS` | Reference air flow | raw x 0.1 | kg/h |  |
| 70 | 1 |  | `MP_DEPASSEMENT_SEUIL_ENCRASSEMENT_MOTEUR` | Exceeding of the engine clogging threshold | enum |  | 0=Engine not clogged, 1=Engine clogged |
| 71 | 2 |  | `MP_COMPTEUR_NB_DEMARRAGE_A_FROID` | Counter of the number of cold engine starts | raw |  |  |

### $C3 - Learned and adaptive values

Request `21 C3 8001` -> `61 FF ...` (15 fields)

| Byte | Len | Mask | Parameter | Meaning | Decode | Unit | States |
|---:|---:|---|---|---|---|---|---|
| 3 | 2 |  | `MP_REGIME_MOTEUR` | Engine speed | raw | Rpm |  |
| 5 | 1 |  | `MP_TENSION_ALIMENTATION_CALCULATEUR_CONTROLE_MOTEUR` | Engine management ECU supply voltage | raw x 0.1 | V |  |
| 6 | 2 |  | `MP_APP_POS_MINI_PEDALE_1` | programming of the accelerator pedal minimum position 1 | raw x 0.1 | mv |  |
| 8 | 2 |  | `MP_APP_POS_MINI_PEDALE_2` | programming of the accelerator pedal minimum position 2 | raw x 0.1 | mv |  |
| 10 | 2 |  | `MP_APP_POS_MAXI_PEDALE_1` | programming of the accelerator pedal maximum position 1 | raw x 0.1 | mv |  |
| 12 | 2 |  | `MP_APP_POS_MAXI_PEDALE_2` | programming of the accelerator pedal maximum position 2 | raw x 0.1 | mv |  |
| 20 | 1 |  | `MP_ETAT_APP_BUTEES_PAPILLON_MOTORISE` | Motorised throttle limit programming status | enum |  | 0=programming not carried out, 1=programming done |
| 21 | 1 |  | `MP_BESOIN_APPRENTISSAGE_BUTEES_PAPILLON` | need for throttle limits programming | enum |  | 0=NO, 1=yes |
| 22 | 2 |  | `MP_VALEUR_APP_LIMP_HOME_BPM_SIGNAL_1` | Programming value of the motorised throttle housing natural position signal 1 | raw x 0.1 | mv |  |
| 24 | 2 |  | `MP_VALEUR_APP_LIMP_HOME_BPM_SIGNAL_2` | Programming value of the motorised throttle housing natural position signal 2 | raw x 0.1 | mv |  |
| 26 | 2 |  | `MP_APPRENTISSAGE_BUTE_MINI_PAPILLON_PISTE_01` | Programming of the butterfly min stop position track 1 | raw x 0.1 | mv |  |
| 28 | 2 |  | `MP_APPRENTISSAGE_BUTE_MINI_PAPILLON_PISTE_02` | Programming of the butterfly min stop position track 2 | raw x 0.1 | mv |  |
| 46 | 1 |  | `MP_ETAT_APP_DEPH_AAC_ADM` | Inlet camshaft dephaser programming status | enum |  | 0=not programmed, 1=programmed |
| 47 | 2 |  | `MP_VALEUR_APPRENTISSAGE_BUTEE_BASSE_DEPHASEUR_AAC_ADMISSION` | Value for initialising the lower limit of the inlet camshaft dephaser | raw x 0.09375 -180 | ° crankshaft |  |
| 72 | 1 |  | `MP_STATUS_PREMIER_APP_DEPH_AAC_ADM` | Status of the first programming of the inlet camshaft dephaser | enum |  | 0=not programmed, 1=programmed |

### $C4 - Engine torque

Request `21 C4 8001` -> `61 FF ...` (7 fields)

| Byte | Len | Mask | Parameter | Meaning | Decode | Unit | States |
|---:|---:|---|---|---|---|---|---|
| 3 | 2 |  | `MP_REGIME_MOTEUR` | Engine speed | raw | Rpm |  |
| 5 | 1 |  | `MP_TENSION_ALIMENTATION_CALCULATEUR_CONTROLE_MOTEUR` | Engine management ECU supply voltage | raw x 0.1 | V |  |
| 6 | 2 |  | `MP_COUPLE_MOTEUR_EFFECTIF_AIR` | Engine torque obtained by managing air flow (setting) | raw x 0.0625 -2000 | Nm |  |
| 8 | 2 |  | `MP_COUPLE_MOTEUR_EFFECTIF_AVANCE` | Engine torque obtained by managing ignition advance (setting) | raw x 0.0625 -2000 | Nm |  |
| 10 | 2 |  | `MP_COUPLE_MOTEUR_AVANCE` | Engine torque obtained by managing ignition advance (actual) | raw x 0.0625 -2000 | Nm |  |
| 12 | 2 |  | `MP_COUPLE_RESISTANT_MOTEUR_ESTIME` | estimated resistive torque | raw x 0.0625 -2000 | Nm |  |
| 14 | 2 |  | `MP_COUPLE_VOLONTE_CONDUCTEUR` | driver's requirement torque | raw x 0.0625 -2000 | Nm |  |

### $CA - Driving data

Request `21 CA 8001` -> `61 FF ...` (28 fields)

| Byte | Len | Mask | Parameter | Meaning | Decode | Unit | States |
|---:|---:|---|---|---|---|---|---|
| 3 | 2 |  | `MP_REGIME_MOTEUR` | Engine speed | raw | Rpm |  |
| 5 | 2 |  | `MP_REGMOTRALENTI` | Reference engine speed at idle | raw | Rpm |  |
| 7 | 1 |  | `MP_TENSION_ALIMENTATION_CALCULATEUR_CONTROLE_MOTEUR` | Engine management ECU supply voltage | raw x 0.1 | V |  |
| 8 | 1 |  | `MP_TEMPERATURE_D_EAU_MOTEUR_d` | engine coolant temperature | raw -50 | deg. C |  |
| 9 | 1 |  | `MP_VITESSE_VEHICULE` | vehicle speed | raw | kph |  |
| 10 | 2 |  | `MP_PEDALE_ACCELERATEUR_1` | accelerator pedal sensor 1 voltage | raw x 10 | mv |  |
| 12 | 2 |  | `MP_PEDALE_ACCELERATEUR_2` | accelerator pedal sensor 2 voltage | raw x 10 | mv |  |
| 14 | 2 |  | `MP_POSPEDACC1` | accelerator pedal position, track 1 | raw x 0.1 | % |  |
| 16 | 2 |  | `MP_POSPEDACC2` | accelerator pedal position, track 2 | raw x 0.1 | % |  |
| 18 | 1 |  | `MP_VITESSE_CONSIGNE_REGULATION_VITESSE` | Cruise control reference speed | raw | kph |  |
| 19 | 1 |  | `MP_ETAT_RVV` | status of the cruise control (RVV) | raw |  |  |
| 20 | 1 |  | `MP_VITESSE_CONSIGNE_LIMITATION_DE_VITESSE` | Speed limiter reference speed | raw | kph |  |
| 21 | 1 |  | `MP_ETAT_LVV` | status of the speed limiter (LVV) | raw |  |  |
| 23 | 1 |  | `MP_ETAT_CONTACTEUR_FREIN_PRINCIPAL` |  | raw |  |  |
| 24 | 1 |  | `MP_ETAT_CONTACTEUR_PEDALE_FREIN` | Brake pedal switch status | enum |  | 0=released position, 1=pressed position |
| 25 | 1 |  | `MP_INFORMATION_CAPTEUR_EMBRAYAGE` | clutch sensor information | enum |  | 0=released position, 1=pressed position |
| 26 | 1 |  | `MP_INFORMATION_POINT_DUR_PEDALE_ACCELERATEUR` | accelerator pedal point of resistance sensor information | enum |  | 0=Tight spot not crossed, 1=Tight spot crossed |
| 28 |  | 00111111 | `MP_RAPPORT_ENGAGE` | gear engaged | enum |  | 0=Neutral or declutched, 1=First gear engaged, 2=Last gear engaged, 3=Third gear engaged, 4=Fourth gear engaged, 5=Fifth gear engaged, 6=Sixth gear engaged, 7=reverse engaged, 8=Uncertain gear |
| 28 |  | 11000000 | `MP_TYPE_BOITE_VITESSES` | type of gearbox | enum |  | 0=Manual gearbox, 1=Automatic gearbox, 2=Piloted manual gearbox |
| 32 | 1 |  | `MP_ETAT_MTH` | Status of the internal combustion engine | enum |  | 1=cut off stalled, 2=in preparation, 3=driven starting, 5=engine running, 6=off, 7=driven restarting |
| 33 | 1 |  | `MP_ETAT_FONCTIONNEMENT_MOTEUR_THERMIQUE` | Internal combustion engine operating status | enum |  | 0=cut-off, 1=idling, 2=pedal, 3=over-revving |
| 34 | 1 |  | `MP_ETAT_REVEIL_CALCULATEUR` | ECU wake-up status | enum |  | 0=Stand-by, 1=partial wake-up, 2=Internal partial wake-up, 3=Transitory status, 4=Main triggering, 5=Downgraded main wake-up, 6=initialisation or becoming dormant |
| 35 | 1 |  | `MP_POSITION_PEDALE_EMBRAYAGE` | clutch pedal position | raw | % |  |
| 36 | 1 |  | `MP_NIVEAU_CARBURANT_AFFICHE` | fuel level displayed | raw | litre |  |
| 37 | 3 |  | `MP_TEMPS_ARRET_MOTEUR` | Engine stopping time | raw | second |  |
| 40 | 1 |  | `MP_TEMPERATURE_EAU_DERNIER_ARRET_MOTEUR` | Coolant temperature at the last engine stop | raw -50 | deg. C |  |
| 42 | 1 |  | `MP_AUTORISATION_DEMARRAGE_CALCULATEURS_BV` | starting authorised by the gearbox ECU | enum |  | 0=starting authorised, 1=starter inhibition |
| 43 | 1 |  | `MP_ETAT_GMP` | status of the power train | enum |  | 0=clutch open, 1=clutch closed |

### $CB - Engine environment

Request `21 CB 8001` -> `61 FF ...` (22 fields)

| Byte | Len | Mask | Parameter | Meaning | Decode | Unit | States |
|---:|---:|---|---|---|---|---|---|
| 3 | 2 |  | `MP_REGIME_MOTEUR` | Engine speed | raw | Rpm |  |
| 5 | 1 |  | `MP_TENSION_ALIMENTATION_CALCULATEUR_CONTROLE_MOTEUR` | Engine management ECU supply voltage | raw x 0.1 | V |  |
| 6 | 1 |  | `MP_TEMP_AIR_ADMISSION_SUP` | Inlet air temperature | raw -50 | deg. C |  |
| 7 | 1 |  | `MP_TEMPERATURE_D_EAU_MOTEUR_d` | engine coolant temperature | raw -50 | deg. C |  |
| 11 | 1 |  | `MP_ETAT_REL_GMV_C5` | status of the relay of the fast speed cooling fan | enum |  | 0=inactive, 1=ACTIVE |
| 12 | 1 |  | `MP_ETAT_GMV_PTIT_C5` | status of the relay of the slow speed cooling fan | enum |  | 0=inactive, 1=ACTIVE |
| 13 | 1 |  | `MP_CONSIGNE_VITESSE_GMV_C5` | cooling fan speed requirement | raw | % |  |
| 14 | 1 |  | `MP_ETAT_RELAIS_GMV` | Status of fan assembly relay | enum |  | 0=status inactive, 1=status active |
| 16 | 1 |  | `MP_ESTIMATION_PUISSANCE_CONSO_COMPRESSEUR_REFRI` | estimate of the mechanical power consumed by the air conditioning compressor | raw x 25 | W |  |
| 23 | 1 |  | `MP_PRESSION_CIRCUIT_REFRIGERANT_a` | refrigerant circuit pressure | raw x 0.1 | bar |  |
| 24 | 2 |  | `MP_TENSION_ALIMENTATION_CAPTEURS_01` | 1 sensors supply voltage | raw x 10 | mv |  |
| 26 | 2 |  | `MP_TENSION_ALIMENTATION_CAPTEURS_02` | 2 sensors supply voltage | raw x 10 | mv |  |
| 28 | 2 |  | `MP_TENSION_ALIMENTATION_CAPTEURS_03` | 3 sensors supply voltage | raw x 10 | mv |  |
| 35 | 1 |  | `MP_PRESSION_HUILE_MOTEUR` | Engine oil pressure | enum |  | 0=pressure insufficient, 1=pressure correct |
| 39 | 1 |  | `MP_COMMANDE_RELAIS_PUISSANCE` | power relay control | enum |  | 0=relay not activated, 1=relay controlled |
| 40 | 1 |  | `MP_ETATCDEDEM` | Starter control status | enum |  | 0=not controlled, 1=controlled |
| 41 | 1 |  | `MP_TEMPERATURE_AIR_EXTERIEUR` | exterior air temperature | raw -40 | deg. C |  |
| 44 | 2 |  | `MP_BRUIT_CAPTEUR_CLIQUETIS` | Noise value measured by the knock detector | raw x 0.1 | mv |  |
| 53 | 1 |  | `MP_INFO_DETECTION_CHOC` | detection of vehicle impact information | enum |  | 0=missing, 1=present |
| 54 | 1 |  | `MP_ETAT_COMMANDE_POMPE_VIDE_ELECTRIQUE` | Status of the electric vacuum pump control | enum |  | 0=inactive, 1=activated |
| 56 | 2 |  | `MP_PRESSION_ATMOSPHERIQUE` | atmospheric pressure | raw +500 | mBar |  |
| 58 | 2 |  | `MP_PRESSION_MASTERVAC` | Pressure in the brake servo | raw +20 | mBar |  |

### $CF - read frame

Request `21 CF 00` -> `61 FF ...` (6 fields)

| Byte | Len | Mask | Parameter | Meaning | Decode | Unit | States |
|---:|---:|---|---|---|---|---|---|
| 3 | 1 |  | `ZAPVNUMBER` | numero de zapv | raw |  |  |
| 4 | 3 |  | `SIGNATURE` | numero de zapv | raw |  |  |
| 7 | 3 |  | `DATE` | numero de zapv | raw |  |  |
| 10 | 3 |  | `MILEAGE` | numero de zapv | raw x 0.064 |  |  |
| 13 | 1 |  | `ERASETYPE` | numero de zapv | raw |  |  |
| 14 | 1 |  | `NUMBERINTERVENTION` | numero de zapv | raw |  |  |

### $DB - adaptation structure

Request `21 DB` -> `61 FF ...` (1 fields)

| Byte | Len | Mask | Parameter | Meaning | Decode | Unit | States |
|---:|---:|---|---|---|---|---|---|
| 3 | 10 |  | `DONNES_ADAPT` | adaptive data | raw |  |  |

## Identification

### ZA - Identification $80 (PSA hardware reference)

Request `21 80`

| Byte | Len | Mask | Parameter | Meaning | Decode | Unit | States |
|---:|---:|---|---|---|---|---|---|
| 3 | 5 |  | `ID_REFERENCE_MATERIEL` | Equipment part number | raw |  |  |
| 8 | 2 |  | `ID_NOM_DU_FOURNISSEUR` | Name of the Supplier | enum |  | 6=ValÚo, 3=BOSCH |
| 10 | 5 |  | `ID_REFERENCE_COMPLEMENTAIRE_MATERIEL` | Equipment additional reference | raw |  |  |
| 19 | 1 |  | `ID_VERSION_DIAGNOSTIC` | diagnostic message system index (of modification) | raw |  |  |

### ZI - Identification $FE (software)

Request `21 FE`

| Byte | Len | Mask | Parameter | Meaning | Decode | Unit | States |
|---:|---:|---|---|---|---|---|---|
| 7 | 1 |  | `ID_REFERENCE_FOURNISSEUR` | Supplier | raw |  |  |
| 8 | 1 |  | `ID_ZI_CODE_SYSTEME` | system | raw |  |  |
| 12 | 1 |  | `ID_FE_APPLICATION_FE` | application | raw |  |  |
| 13 | 1 |  | `ID_VERSION_DU_LOGICIEL` | software version | raw |  |  |
| 14 | 2 |  | `ID_TRACABILITE_INDICE_EVOLUTION_EDITION` | software edition | raw |  |  |
| 23 | 1 |  | `ID_NOMBRE_DE_TELECHARGEMENT` | number of downloads | raw |  |  |
| 24 | 3 |  | `ID_REFERENCE_LOGICIEL` | software reference | raw |  |  |

### ZF - Traceability $82

Request `21 82`

| Byte | Len | Mask | Parameter | Meaning | Decode | Unit | States |
|---:|---:|---|---|---|---|---|---|
| 3 | 1 |  | `INFTYP` | Traceability record type | raw |  |  |
| 4 | 3 |  | `DATEFAB` | hardware reference | raw |  |  |

## Fault codes

Read: `17 FF00` -> `57 <count> [ <DTC hi> <DTC lo> <status> ] x N`

Each record is 3 bytes: a 2-byte PSA fault code followed by a status byte. The full code list for this ECU is in `diagbox_v46_21_dtc.md` (291 codes).

Clear: `14 FF00` -> `54 FF 00`

### Freeze frame (conditions when the fault was stored)

Request `21 87 <DTC hi> <DTC lo>` -> `61 87 <DTC hi> <DTC lo> <block>`. The block layout depends on which of the 24 groups the DTC belongs to; the block starts at byte 5. Group membership and all 24 layouts are in the JSON under `services[].units[].dynamic`.

Note the freeze-frame fields use their own scaling, different from the live pages: engine speed is `raw x 0.25` and coolant temperature `raw - 40`, whereas page $CB uses `raw x 1` and `raw - 50`.

Largest group `DTC_CODE_VA_GROUP3` (20 fields):

| Byte | Len | Mask | Parameter | Meaning | Decode | Unit | States |
|---:|---:|---|---|---|---|---|---|
| 5 | 1 |  | `CA_REMPLISSAGE_CONSIGNE` | reference filling | raw x 0.392157 | % |  |
| 6 | 1 |  | `CA_FACTEUR_CORRECTION_RICHESSE_AMONT` | upstream mixture correction factor | raw x 0.78125 -100 |  |  |
| 7 | 1 |  | `CA_FACTEUR_CORRECTION_RICHESSE_AVAL` | downstream mixture correction factor | raw x 0.78125 -100 |  |  |
| 8 | 2 |  | `CA_ETAT_REGULATION_SONDE_OXYGENE_AMONT` | upstream oxygen sensor regulation status | enum |  | 0=open loop (conditions for switching to a closed loop not yet satisfied), 1=closed loop, 2=open loop (special driving conditions), 3=open loop (fault), 4=closed loop but fault on an oxygen sensor |
| 10 | 2 |  | `CA_REGIME_MOTEUR` | Engine speed | raw x 0.25 | Rpm |  |
| 12 | 1 |  | `CA_TEMPERATURE_D_EAU_MOTEUR` | engine coolant temperature | raw -40 | °C |  |
| 13 | 1 |  | `CA_VITESSE_VEHICULE` | vehicle speed | raw | kph |  |
| 14 | 1 |  | `CA_PRESSION_TUBULURE_AIR_ADMISSION` | intake air manifold pressure | raw x 0.1 | mbar |  |
| 15 | 2 |  | `CA_TENSION_BATTERIE_CALCULATEUR_CONTROLE_MOTEUR` | Engine management ECU supply voltage | raw x 0.001 | V |  |
| 17 | 1 |  | `CA_TEMPERATURE_ADMISSION` | Inlet air temperature | raw -40 | °C |  |
| 18 | 3 |  | `CA_KILOMETER` | Mileage | raw | km |  |
| 21 | 2 |  | `CA_SIGNAL_POSITION_PEDALE_ACCELERATEUR_PISTE_1` | Position signal S1 of the accelerator pedal | enum | % |  |
| 23 | 2 |  | `CA_ETAT_MOTEUR_a` | engine status | enum |  | 1=cut off stalled, 2=in preparation, 3=driven starting, 4=autonomous starting, 5=engine running, 6=off, 7=driven restarting, 8=autonomous restarting |
| 25 | 2 |  | `CA_RAPPORT_BOITE_VITESSES` | gearbox ratio | enum |  | 1=1st, 2=2nd, 3=3rd, 4=4th, 5=5th |
| 27 | 2 |  | `CA_ANGLE_PAPILLON_CONSIGNE` | reference throttle angle | enum | % |  |
| 29 | 2 |  | `CA_ANGLE_PAPILLON_MESURE` | measured throttle angle | enum | % |  |
| 31 | 2 |  | `CA_TENSION_ALIMENTATION_CAPTEURS_03` | 3 sensors supply voltage | enum | V |  |
| 33 | 2 |  | `CA_APPRENTISSAGE_POSITION_MINIMUM_PEDALE_ACCELERATEUR_01` | programming of the accelerator pedal minimum position 1 | enum | % |  |
| 35 | 2 |  | `CA_APPRENTISSAGE_POSITION_MINIMUM_PEDALE_ACCELERATEUR_02` | programming of the accelerator pedal minimum position 2 | enum | % |  |
| 37 | 2 |  | `CA_RCO_COMMANDE_BOITIER_PAPILLON_MOTORISE` | Motorised throttle housing OCR control | enum | % |  |

## Actuator tests

All actuator tests use InputOutputControlByLocalIdentifier:

```
30 <actuator> 00   start      -> 70 <actuator> <status>
30 <actuator> 01   read state -> 70 <actuator> <status>
30 <actuator> 11   stop       -> 70 <actuator> <status>
```

| Actuator byte | Test | Max duration |
|---|---|---|
| `51` | ignition coil 1 | - |
| `52` | ignition coil 2 | - |
| `53` | ignition coil 3 | - |
| `54` | ignition coil 4 | - |
| `21` | Upstream oxygen sensor heating | - |
| `22` | Downstream oxygen sensor heating | - |
| `B8` | Inlet camshaft dephaser | 10000 ms |
| `61` | Canister purge solenoid valve | - |
| `57` | high speed fan assembly or chopper | - |
| `58` | low speed fan unit | - |
| `11` | Cylinder 1 petrol injector | - |
| `12` | Cylinder 2 petrol injector | - |
| `13` | Cylinder 3 petrol injector | - |
| `14` | Cylinder 4 petrol injector | - |
| `45` | motorised throttle | - |
| `19` | power relay | - |

## Resets and learned-value clearing

| Frame | Meaning |
|---|---|
| `11 B0` | Software reset of the ECU |
| `11 C2` | Reset motorised-throttle (BPM) learned values |
| `11 C3` | Reset motorised-throttle (BPM) learned values |
| `11 C4` | Reset motorised-throttle (BPM) learned values |
| `11 C5` | Reset variable-valve-timing learned values |
| `11 C6` | Reset variable-valve-timing learned values |
| `11 C7` | Reset variable-valve-timing learned values |
| `11 CB` | Reset variable-valve-timing learned values |
| `11 CD` | Reset motorised-throttle (BPM) learned values |
| `11 CE` | Reset motorised-throttle (BPM) learned values |
| `11 D1` | Reset variable-valve-timing learned values |
| `11 D2` | Reset variable-valve-timing learned values |
| `11 D3` | Reset variable-valve-timing learned values |
| `11 FF` | Re-centre all learned values |

## Routines

| Frame | Meaning |
|---|---|
| `32 BC 00` | Inhibit level-2 safety diagnostics |
| `32 BC 01` | Inhibit level-2 safety diagnostics - status |
| `31 B3 00 ........` | Forced regeneration $B3 - start |
| `31 B8 00 31` | Forced regeneration $B8 - start |
| `31 B8 01 31` | Forced regeneration $B8 - status |
| `31 B8 11 31` | Forced regeneration $B8 - stop |
| `31 01 DFAE ........` | SRBLID_DF |
| `31 B0 00` | Immobiliser pairing - start |
| `31 B0 01` | Immobiliser pairing - status |
| `31 B3 00 ........` | Immobiliser pairing - start |
| `31 .. ..` | start |

## Security access

`27 83` returns a seed, `27 84 ........` sends the computed key. The key algorithm lives in the communication library `Cal458.dll` and is not stored in the databases.

Security access is required for writing configuration; reading configuration (`21 A0`) is not protected.

## Telecoding (configuration)

Read the whole configuration block with `21 A0`; write it back with a `34 A0 ...` Request Download frame. The write frames differ per configuration generation:

### Reading: `21 A0`

The answer is `61 A0 <index> <block>`. Byte 3 is `CONFIG_INDICE_TELECODAGE`, the configuration-layout index, and it selects which of the 5 layouts applies. Group `..._07` means index `0x07`, and so on; `INDICE_TELECODAGE` is the fallback layout. Bit-addressed options carry a mask - the option is that bit of the byte at the given position.

#### Layout `CONFIG_INDICE_TELECODAGE_07` (41 options)

| Byte | Bit mask | Parameter | Meaning |
|---:|---|---|---|
| 4 | - | `FPO` | engine cooling management |
| 5 | - | `PCPO` | air conditioning pressure sensor |
| 6 | - | `BVPO` | gearbox |
| 7 | - | `CAPO` | associated alternator class |
| 8 | - | `CPO` |  |
| 9 | - | `CHAPO` |  |
| 10 | 01000000 | `UCPO_AMVAR_CAN` |  |
| 10 | 00100000 | `UCPO_CAPTEUR_EAU` | water in fuel sensor |
| 10 | 10000000 | `UCPO_EASYMOVE` | electric parking brake |
| 10 | 00000001 | `UCPO_ESP` | stability control (ESP) |
| 10 | 00000100 | `UCPO_RTE` | exhaust heat recovery |
| 10 | 00000010 | `UCPO_RVV1` |  |
| 11 | 00000100 | `UCPO_ABS` | ABS |
| 11 | 00000010 | `UCPO_DA` | power steering |
| 11 | 01000000 | `UCPO_DEMARRAGE` |  |
| 11 | 00000001 | `UCPO_GPL` |  |
| 11 | 00010000 | `UCPO_LVV` | speed limiter |
| 11 | 00000010 | `UCPO_RVV2` | cruise control |
| 12 | - | `CFG_000_CMM_FPR` | engine cooling management |
| 13 | - | `CFG_000_CMM_PCPR` | air conditioning pressure sensor |
| 14 | - | `CFG_000_CMM_BVPR` | gearbox |
| 15 | - | `CFG_000_CMM_CAPR` | associated alternator class |
| 16 | - | `CFG_000_CMM_CPR` | Body type |
| 17 | - | `CFG_000_CMM_CHAPR` | Additional heating |
| 18 | 01000000 | `CFG_000_CMM_UCPR_AMVAR_CAN` |  |
| 18 | 00100000 | `CFG_000_CMM_UCPR_CAPTEUR_EAU` | water in fuel sensor |
| 18 | 10000000 | `CFG_000_CMM_UCPR_EASYMOVE` | electric parking brake |
| 18 | 00000001 | `CFG_000_CMM_UCPR_ESP` | stability control (ESP) |
| 18 | 00000100 | `CFG_000_CMM_UCPR_RTE` | exhaust heat recovery |
| 18 | 00000010 | `CFG_000_CMM_UCPR_RVV1` |  |
| 18 | 00011000 | `RESERVE_34` |  |
| 19 | 00000100 | `CFG_000_CMM_UCPR_ABS` | ABS |
| 19 | 00000010 | `CFG_000_CMM_UCPR_DA` | power steering |
| 19 | 01000000 | `CFG_000_CMM_UCPR_DAMP` | starting and switching off of the engine controlled |
| 19 | 00000001 | `CFG_000_CMM_UCPR_GPL` |  |
| 19 | 00010000 | `CFG_000_CMM_UCPR_LVV` | speed limiter |
| 19 | 00100000 | `CFG_000_CMM_UCPR_RVV2` | cruise control |
| 19 | 10001000 | `RESERVE_37` |  |
| 20 | - | `SITE` | Configuration site code |
| 21 | - | `SIGN` | Tool signature |
| 24 | - | `NUM` | Number of configuration writes |

#### Layout `CONFIG_INDICE_TELECODAGE_08` (40 options)

| Byte | Bit mask | Parameter | Meaning |
|---:|---|---|---|
| 4 | - | `FPO` | engine cooling management |
| 5 | - | `PCPO` | air conditioning pressure sensor |
| 6 | - | `BVPO` | gearbox |
| 7 | - | `CAPO` | associated alternator class |
| 10 | 00100000 | `UCPO_CAPTEUR_EAU` | water in fuel sensor |
| 10 | 10000000 | `UCPO_EASYMOVE` | electric parking brake |
| 10 | 00000001 | `UCPO_ESP` | stability control (ESP) |
| 10 | 00000100 | `UCPO_RTE` | exhaust heat recovery |
| 10 | 00000010 | `UCPO_RVV2` | cruise control |
| 11 | 00000100 | `UCPO_ABS` | ABS |
| 11 | 00001000 | `UCPO_CE` | clutch switch |
| 11 | 00000010 | `UCPO_DA` | power steering |
| 11 | 01000000 | `UCPO_DEMARRAGE` |  |
| 11 | 00010000 | `UCPO_LVV` | speed limiter |
| 13 | - | `CFG_000_CMM_FPR` | engine cooling management |
| 14 | - | `CFG_000_CMM_PCPR` | air conditioning pressure sensor |
| 15 | - | `CFG_000_CMM_BVPR` | gearbox |
| 16 | - | `CFG_000_CMM_CAPR` | associated alternator class |
| 17 | - | `CFG_000_CMM_CPR` | Body type |
| 18 | - | `CFG_000_CMM_CHAPR` | Additional heating |
| 19 | 00001000 | `CFG_000_CMM_UCPR_ACC` |  |
| 19 | 01000000 | `CFG_000_CMM_UCPR_AMVAR_CAN` |  |
| 19 | 00100000 | `CFG_000_CMM_UCPR_CAPTEUR_EAU` | water in fuel sensor |
| 19 | 10000000 | `CFG_000_CMM_UCPR_EASYMOVE` | electric parking brake |
| 19 | 00000001 | `CFG_000_CMM_UCPR_ESP` | stability control (ESP) |
| 19 | 00000100 | `CFG_000_CMM_UCPR_RTE` | exhaust heat recovery |
| 19 | 00000010 | `CFG_000_CMM_UCPR_RVV` | cruise control |
| 19 | 00010000 | `CFG_000_CMM_UCPR_VP` |  |
| 20 | 00000100 | `CFG_000_CMM_UCPR_ABS` | ABS |
| 20 | 10000000 | `CFG_000_CMM_UCPR_ACC_S_AND_G` |  |
| 20 | 00100000 | `CFG_000_CMM_UCPR_ACGF` |  |
| 20 | 00001000 | `CFG_000_CMM_UCPR_CE` | clutch switch |
| 20 | 00000010 | `CFG_000_CMM_UCPR_DA` | power steering |
| 20 | 01000000 | `CFG_000_CMM_UCPR_DAMP` | starting and switching off of the engine controlled |
| 20 | 00000001 | `CFG_000_CMM_UCPR_GPL` |  |
| 20 | 00010000 | `CFG_000_CMM_UCPR_LVV` | speed limiter |
| 21 | - | `CFG_000_CMM_GXVVPR` | Cruise control / speed limiter |
| 22 | - | `SITE` | Configuration site code |
| 23 | - | `SIGN` | Tool signature |
| 26 | - | `NUM` | Number of configuration writes |

#### Layout `CONFIG_INDICE_TELECODAGE_09` (43 options)

| Byte | Bit mask | Parameter | Meaning |
|---:|---|---|---|
| 4 | - | `FPO` | engine cooling management |
| 5 | - | `PCPO` | air conditioning pressure sensor |
| 6 | - | `BVPO` | gearbox |
| 7 | - | `CAPO` | associated alternator class |
| 10 | 00100000 | `UCPO_CAPTEUR_EAU` | water in fuel sensor |
| 10 | 10000000 | `UCPO_EASYMOVE` | electric parking brake |
| 10 | 00000001 | `UCPO_ESP` | stability control (ESP) |
| 10 | 00000100 | `UCPO_RTE` | exhaust heat recovery |
| 10 | 00000010 | `UCPO_RVV2` | cruise control |
| 11 | 00000100 | `UCPO_ABS` | ABS |
| 11 | 00001000 | `UCPO_CE` | clutch switch |
| 11 | 00000010 | `UCPO_DA` | power steering |
| 11 | 01000000 | `UCPO_DEMARRAGE` |  |
| 11 | 00010000 | `UCPO_LVV` | speed limiter |
| 12 | 00000001 | `UCPO_BPGA` | supplies protection and management unit |
| 14 | - | `CFG_DF0_CMM_FPR_009` | engine cooling management |
| 15 | - | `CFG_DF2_CMM_PCPR_009` | air conditioning pressure sensor |
| 16 | - | `CFG_DEW_CMM_BVPR_009` | gearbox |
| 17 | - | `CFG_DEX_CMM_CAPR_009` | associated alternator class |
| 18 | - | `CFG_DEZ_CMM_CPR_009` | Body type |
| 19 | - | `CFG_DEY_CMM_CHAPR_009` | additional heating |
| 20 | 00001000 | `CFG_000_CMM_UCPR_ACC_009` |  |
| 20 | 01000000 | `CFG_000_CMM_UCPR_AMVAR_CAN_009` |  |
| 20 | 00100000 | `CFG_000_CMM_UCPR_CAPTEUR_EAU_009` | water in fuel sensor |
| 20 | 10000000 | `CFG_000_CMM_UCPR_EASYMOVE_009` | electric parking brake |
| 20 | 00000001 | `CFG_000_CMM_UCPR_ESP_009` | stability control (ESP) |
| 20 | 00000100 | `CFG_000_CMM_UCPR_RTE_009` | exhaust heat recovery |
| 20 | 00000010 | `CFG_000_CMM_UCPR_RVV_009` | cruise control |
| 20 | 00010000 | `CFG_000_CMM_UCPR_VP_009` |  |
| 21 | 00000100 | `CFG_000_CMM_UCPR_ABS_009` | ABS |
| 21 | 10000000 | `CFG_000_CMM_UCPR_ACC_S_AND_G_009` |  |
| 21 | 00100000 | `CFG_000_CMM_UCPR_ACGF_009` |  |
| 21 | 00001000 | `CFG_000_CMM_UCPR_CE_009` | clutch switch |
| 21 | 01000000 | `CFG_000_CMM_UCPR_DAMP_009` | starting and switching off of the engine controlled |
| 21 | 00000010 | `CFG_000_CMM_UCPR_DA_009` | power steering |
| 21 | 00000001 | `CFG_000_CMM_UCPR_GPL_009` |  |
| 21 | 00010000 | `CFG_000_CMM_UCPR_LVV_009` | speed limiter |
| 22 | 00000001 | `CFG_000_CMM_UCPR_BPGA_009` | supplies protection and management unit |
| 22 | 11111110 | `RESERVE6` |  |
| 23 | - | `CFG_DF1_CMM_GXVVPR_009` | cruise control/vehicle speed limitation |
| 24 | - | `SITE` | Configuration site code |
| 25 | - | `SIGN` | Tool signature |
| 28 | - | `NUM` | Number of configuration writes |

#### Layout `CONFIG_INDICE_TELECODAGE_0A` (46 options)

| Byte | Bit mask | Parameter | Meaning |
|---:|---|---|---|
| 4 | - | `FPO` | engine cooling management |
| 5 | - | `PCPO` | air conditioning pressure sensor |
| 6 | - | `BVPO` | gearbox |
| 7 | - | `CAPO` | associated alternator class |
| 8 | - | `CPO` |  |
| 9 | - | `CHAPO` |  |
| 10 | 00100000 | `UCPO_CAPTEUR_EAU` | water in fuel sensor |
| 10 | 10000000 | `UCPO_EASYMOVE` | electric parking brake |
| 10 | 00000001 | `UCPO_ESP` | stability control (ESP) |
| 10 | 00000100 | `UCPO_RTE` | exhaust heat recovery |
| 10 | 00000010 | `UCPO_RVV2` | cruise control |
| 11 | 00000100 | `UCPO_ABS` | ABS |
| 11 | 00001000 | `UCPO_CE` | clutch switch |
| 11 | 00000010 | `UCPO_DA` | power steering |
| 11 | 01000000 | `UCPO_DEMARRAGE` |  |
| 11 | 00010000 | `UCPO_LVV` | speed limiter |
| 12 | 00000001 | `UCPO_BPGA` | supplies protection and management unit |
| 14 | - | `CFG_EYL_CMM_FPR_010` |  |
| 15 | - | `CFG_EYN_CMM_PCPR_010` |  |
| 16 | - | `CFG_EYH_CMM_BVPR_010` |  |
| 17 | - | `CFG_EYI_CMM_CAPR_010` |  |
| 18 | - | `CFG_EYK_CMM_CPR_010` | Body type |
| 19 | - | `CFG_EYJ_CMM_CHAPR_010` | Additional heating |
| 20 | 00001000 | `CFG_000_CMM_UCPR_ACC_010` |  |
| 20 | 01000000 | `CFG_000_CMM_UCPR_AMVAR_CAN_010` |  |
| 20 | 00100000 | `CFG_000_CMM_UCPR_CAPTEUR_EAU_010` | water in fuel sensor |
| 20 | 10000000 | `CFG_000_CMM_UCPR_EASYMOVE_010` | electric parking brake |
| 20 | 00000001 | `CFG_000_CMM_UCPR_ESP_010` | stability control (ESP) |
| 20 | 00000100 | `CFG_000_CMM_UCPR_RTE_010` | exhaust heat recovery |
| 20 | 00000010 | `CFG_000_CMM_UCPR_RVV_010` | cruise control |
| 20 | 00010000 | `CFG_000_CMM_UCPR_VP_010` |  |
| 21 | 00000100 | `CFG_000_CMM_UCPR_ABS_010` | ABS |
| 21 | 10000000 | `CFG_000_CMM_UCPR_ACC_S_AND_G_010` |  |
| 21 | 00100000 | `CFG_000_CMM_UCPR_ACGF_010` |  |
| 21 | 00001000 | `CFG_000_CMM_UCPR_CE_010` | clutch switch |
| 21 | 01000000 | `CFG_000_CMM_UCPR_DAMP_010` | starting and switching off of the engine controlled |
| 21 | 00000010 | `CFG_000_CMM_UCPR_DA_010` | power steering |
| 21 | 00000001 | `CFG_000_CMM_UCPR_GPL_010` |  |
| 21 | 00010000 | `CFG_000_CMM_UCPR_LVV_010` | speed limiter |
| 22 | 00000001 | `CFG_000_CMM_UCPR_BPGA_010` | supplies protection and management unit |
| 22 | 00000110 | `RESERVE6_1` |  |
| 22 | 11111000 | `RESERVE6_2` |  |
| 23 | - | `CFG_EYM_CMM_GXVVPR_010` | Cruise control / speed limiter |
| 24 | - | `SITE` | Configuration site code |
| 25 | - | `SIGN` | Tool signature |
| 28 | - | `NUM` | Number of configuration writes |

#### Layout `INDICE_TELECODAGE` (38 options)

| Byte | Bit mask | Parameter | Meaning |
|---:|---|---|---|
| 4 | - | `FPO` | engine cooling management |
| 5 | - | `PCPO` | air conditioning pressure sensor |
| 6 | - | `BVPO` | gearbox |
| 7 | - | `CAPO` | associated alternator class |
| 10 | 10000000 | `UCPO_EASYMOVE` | electric parking brake |
| 10 | 00000001 | `UCPO_ESP` | stability control (ESP) |
| 10 | 00000010 | `UCPO_RVV2` | cruise control |
| 11 | 00000100 | `UCPO_ABS` | ABS |
| 11 | 00001000 | `UCPO_CE` | clutch switch |
| 11 | 00000010 | `UCPO_DA` | power steering |
| 11 | 01000000 | `UCPO_DEMARRAGE` |  |
| 11 | 00010000 | `UCPO_LVV` | speed limiter |
| 13 | - | `CFG_000_CMM_FPR` | engine cooling management |
| 14 | - | `CFG_000_CMM_PCPR` | air conditioning pressure sensor |
| 15 | - | `CFG_000_CMM_BVPR` | gearbox |
| 16 | - | `CFG_000_CMM_CAPR` | associated alternator class |
| 17 | - | `CFG_000_CMM_CPR` | Body type |
| 18 | - | `CFG_000_CMM_CHAPR` | Additional heating |
| 19 | 00001000 | `CFG_000_CMM_UCPR_ACC` |  |
| 19 | 01000000 | `CFG_000_CMM_UCPR_AMVAR_CAN` |  |
| 19 | 00100000 | `CFG_000_CMM_UCPR_CAPTEUR_EAU` | water in fuel sensor |
| 19 | 10000000 | `CFG_000_CMM_UCPR_EASYMOVE` | electric parking brake |
| 19 | 00000001 | `CFG_000_CMM_UCPR_ESP` | stability control (ESP) |
| 19 | 00000100 | `CFG_000_CMM_UCPR_RTE` | exhaust heat recovery |
| 19 | 00000010 | `CFG_000_CMM_UCPR_RVV` | cruise control |
| 19 | 00010000 | `CFG_000_CMM_UCPR_VP` |  |
| 20 | 00000100 | `CFG_000_CMM_UCPR_ABS` | ABS |
| 20 | 10000000 | `CFG_000_CMM_UCPR_ACC_S_AND_G` |  |
| 20 | 00100000 | `CFG_000_CMM_UCPR_ACGF` |  |
| 20 | 00001000 | `CFG_000_CMM_UCPR_CE` | clutch switch |
| 20 | 00000010 | `CFG_000_CMM_UCPR_DA` | power steering |
| 20 | 01000000 | `CFG_000_CMM_UCPR_DAMP` | starting and switching off of the engine controlled |
| 20 | 00000001 | `CFG_000_CMM_UCPR_GPL` |  |
| 20 | 00010000 | `CFG_000_CMM_UCPR_LVV` | speed limiter |
| 21 | - | `CFG_000_CMM_GXVVPR` | Cruise control / speed limiter |
| 22 | - | `SITE` | Configuration site code |
| 23 | - | `SIGN` | Tool signature |
| 26 | - | `NUM` | Number of configuration writes |

### Writing: `34 A0 ...`

One flat frame. Bytes 3-5 are the start address of the zone, byte 6 its length and byte 7 the configuration index; the options then follow. Options with a mask share a byte, the rest take a whole byte each. `RESERVE*` entries mark the bits that must be left alone - read the block first and only flip the bits you mean to change.

| Byte | Len | Mask | Parameter | Meaning | Decode | Unit | States |
|---:|---:|---|---|---|---|---|---|
| 3 | 1 |  | `CONFIG_PARAIN1` | Zone start address | raw |  |  |
| 4 | 1 |  | `CONFIG_PARAIN2` | Zone start address | raw |  |  |
| 5 | 1 |  | `CONFIG_PARAIN3` | Zone start address | raw |  |  |
| 6 | 1 |  | `CONFIG_MEMSIZE` | Payload length to write | raw |  |  |
| 7 | 1 |  | `CONFIG_INDICE_TELECODAGE` | Configuration layout index | raw |  |  |
| 8 | 1 |  | `CFG_000_CMM_FPR` | engine cooling management | enum |  | 247=fan assembly - 1 speed (without air conditioning), 239=2/3 speed fan unit (with air conditioning), 127=control by chopper |
| 9 | 1 |  | `CFG_000_CMM_PCPR` | air conditioning pressure sensor | enum |  | 254=without air conditioning, 247=linear pressure switch |
| 10 | 1 |  | `CFG_000_CMM_BVPR` | gearbox | enum |  | 254=manual gearbox, 251=AT8 type automatic gearbox, 247=AT6 type automatic gearbox |
| 11 | 1 |  | `CFG_000_CMM_CAPR` | associated alternator class | enum |  | 253=category 8 or 8+, 247=category 12, 239=category 15 |
| 12 | 1 |  | `CFG_000_CMM_CPR` | Body type | raw |  |  |
| 13 | 1 |  | `CFG_000_CMM_CHAPR` | Additional heating | raw |  |  |
| 14 |  | 01111100 | `RESERVE3` |  | raw |  |  |
| 14 |  | 00000001 | `CFG_000_CMM_UCPR_ESP` | stability control (ESP) | enum |  | 0=present, 1=absent |
| 14 |  | 00100000 | `CFG_000_CMM_UCPR_RVV2` | cruise control | enum |  | 0=present, 1=absent |
| 14 |  | 10000000 | `CFG_000_CMM_UCPR_EASYMOVE` | electric parking brake | enum |  | 0=present, 1=absent |
| 15 |  | 10100001 | `RESERVE4` |  | raw |  |  |
| 15 |  | 00000010 | `CFG_000_CMM_UCPR_DA` | power steering | enum |  | 0=present, 1=absent |
| 15 |  | 00001000 | `CFG_000_CMM_UCPR_CE` | clutch switch | enum |  | 0=present, 1=absent |
| 15 |  | 00000100 | `CFG_000_CMM_UCPR_ABS` | ABS | enum |  | 0=present, 1=absent |
| 15 |  | 00010000 | `CFG_000_CMM_UCPR_LVV` | speed limiter | enum |  | 0=present, 1=absent |
| 15 |  | 01000000 | `CFG_000_CMM_UCPR_DAMP` | starting and switching off of the engine controlled | enum |  | 0=present, 1=absent |
| 16 | 1 |  | `CFG_000_CMM_GXVVPR` | Cruise control / speed limiter | raw |  |  |
| 17 | 1 |  | `SITE` | Configuration site code | raw |  |  |
| 18 | 3 |  | `SIGN` | Tool signature | raw |  |  |

### Write-frame variants

| Frame template | Purpose |
|---|---|
| `34 A0 .. .. ..` | Write configuration $A0 |
| `34 A0 .. .. .. .. .. .. .. .. .. .. .. .. .. .. .. .. .. .. .. .. .. .. .. ...... ..` | Write configuration $A0 |
| `34 A0 00 00 00 0E .................. .. ...... ..` | Write configuration $A0 |
| `34 A0 .. .. .. .. .. ............ .. .. .... .. ...... ..` | Write configuration $A0 |
| `34 A0 .. .. .. .. .. .. .. .. .. .. .. .... .. .. ...... ..` | Temporary write frame used by automatic configuration |
| `34 A0 00 00 00 0D .................. .. ...... ..` | Write configuration $A0 |
| `34 A0 00 00 00 0E .................... .. ...... ..` | Write configuration $A0 |
| `34 A0 00 00 00 0F ...................... .. ...... ..` | Write configuration $A0 |
| `34 A0 00 00 00 0F ...................... .. ...... ..` | Write configuration $A0 |
| `34 B0 000000 05 ........ .. ..` | Engine ECU programming |
| `34 B2 00 00 00 .. .................... .. ..` | Write homologation reference |
| `34 CF 00 00 00 09 ...... ...... ...... ..` | Write ZAPV configuration |
| `34 B2 00 00 00 .. .................... .. ..` | Write homologation reference |

### Screen `TELECODAGE`

| Parameter | Meaning | Options |
|---|---|---|
| `CFG_000_CMM_BVPR` | gearbox | 254=manual gearbox, 251=AT8 type automatic gearbox, 247=AT6 type automatic gearbox |
| `CFG_000_CMM_CAPR` | associated alternator class | 253=category 8 or 8+, 247=category 12, 239=category 15 |
| `CFG_000_CMM_FPR` | engine cooling management | 247=fan assembly - 1 speed (without air conditioning), 239=2/3 speed fan unit (with air conditioning), 127=control by chopper |
| `CFG_000_CMM_PCPR` | air conditioning pressure sensor | 254=without air conditioning, 247=linear pressure switch |
| `CFG_000_CMM_UCPR_ABS` | ABS | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_CAPTEUR_EAU` | water in fuel sensor | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_CE` | clutch switch | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_DA` | power steering | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_DAMP` | starting and switching off of the engine controlled | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_EASYMOVE` | electric parking brake | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_ESP` | stability control (ESP) | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_LVV` | speed limiter | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_RTE` | exhaust heat recovery | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_RVV` | cruise control | 0=present, 1=absent |

### Screen `TELECODAGES`

| Parameter | Meaning | Options |
|---|---|---|
| `CFG_000_CMM_BVPR` | gearbox | 254=manual gearbox, 251=AT8 type automatic gearbox, 247=AT6 type automatic gearbox |
| `CFG_000_CMM_CAPR` | associated alternator class | 253=category 8 or 8+, 247=category 12, 239=category 15 |
| `CFG_000_CMM_FPR` | engine cooling management | 247=fan assembly - 1 speed (without air conditioning), 239=2/3 speed fan unit (with air conditioning), 127=control by chopper |
| `CFG_000_CMM_PCPR` | air conditioning pressure sensor | 254=without air conditioning, 247=linear pressure switch |
| `CFG_000_CMM_UCPR_ABS` | ABS | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_ABS_009` | ABS | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_BPGA` | supplies protection and management unit | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_BPGA_009` | supplies protection and management unit | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_CAPTEUR_EAU` | water in fuel sensor | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_CAPTEUR_EAU_009` | water in fuel sensor | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_CE` | clutch switch | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_CE_009` | clutch switch | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_DA` | power steering | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_DAMP` | starting and switching off of the engine controlled | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_DAMP_009` | starting and switching off of the engine controlled | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_DA_009` | power steering | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_EASYMOVE` | electric parking brake | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_EASYMOVE_009` | electric parking brake | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_ESP` | stability control (ESP) | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_ESP_009` | stability control (ESP) | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_LVV` | speed limiter | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_LVV_009` | speed limiter | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_RTE` | exhaust heat recovery | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_RTE_009` | exhaust heat recovery | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_RVV` | cruise control | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_RVV2` | cruise control | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_RVV_009` | cruise control | 0=present, 1=absent |
| `CFG_DEW_CMM_BVPR_009` | gearbox | 254=manual gearbox, 251=AT8 type automatic gearbox, 247=AT6 type automatic gearbox |
| `CFG_DEX_CMM_CAPR_009` | associated alternator class | 253=category 8 or 8+, 247=category 12, 239=category 15 |
| `CFG_DF0_CMM_FPR_009` | engine cooling management | 247=fan assembly - 1 speed (without air conditioning), 239=2/3 speed fan unit (with air conditioning), 127=control by chopper |
| `CFG_DF2_CMM_PCPR_009` | air conditioning pressure sensor | 254=without air conditioning, 247=linear pressure switch |

### Screen `TELECODAGE_J`

| Parameter | Meaning | Options |
|---|---|---|
| `CFG_000_CMM_BVPR` | gearbox | 254=manual gearbox, 253=manual gearbox, 191=AT8 type automatic gearbox, 247=AT6 type automatic gearbox |
| `CFG_000_CMM_CAPR` | associated alternator class | 253=category 8 or 8+, 247=category 12, 239=category 15 |
| `CFG_000_CMM_CHAPR` | additional heating | 255=All models |
| `CFG_000_CMM_CPR` | bodywork | 254=manual gearbox, 247=AT8 type automatic gearbox, 255=AT6 type automatic gearbox |
| `CFG_000_CMM_FPR` | engine cooling management | 247=fan assembly - 1 speed (without air conditioning), 239=2/3 speed fan unit (with air conditioning), 127=control by chopper |
| `CFG_000_CMM_PCPR` | air conditioning pressure sensor | 254=without air conditioning, 247=linear pressure switch |
| `CFG_000_CMM_UCPR_ABS` | ABS | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_CAPTEUR_EAU` | water in fuel sensor | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_DA` | power steering | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_DAMP` | starting and switching off of the engine controlled | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_EASYMOVE` | electric parking brake | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_ESP` | stability control (ESP) | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_LVV` | speed limiter | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_RTE` | exhaust heat recovery | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_RVV2` | cruise control | 0=present, 1=absent |

### Screen `TELECODAGE_N`

| Parameter | Meaning | Options |
|---|---|---|
| `CFG_000_CMM_UCPR_ABS_009` | ABS | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_BPGA_009` | supplies protection and management unit | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_CE_009` | clutch switch | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_DAMP_009` | starting and switching off of the engine controlled | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_DA_009` | power steering | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_EASYMOVE_009` | electric parking brake | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_ESP_009` | stability control (ESP) | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_LVV_009` | speed limiter | 0=present, 1=absent |
| `CFG_000_CMM_UCPR_RVV_009` | cruise control | 0=present, 1=absent |
| `CFG_DEW_CMM_BVPR_009` | gearbox | 254=manual gearbox, 251=AT8 type automatic gearbox, 247=AT6 type automatic gearbox |
| `CFG_DEX_CMM_CAPR_009` | associated alternator class | 253=category 8 or 8+, 247=category 12, 239=category 15 |
| `CFG_DEY_CMM_CHAPR_009` | additional heating | 254=no cabin heating element |
| `CFG_DF0_CMM_FPR_009` | engine cooling management | 247=fan assembly - 1 speed (without air conditioning), 239=2/3 speed fan unit (with air conditioning), 127=control by chopper |
| `CFG_DF1_CMM_GXVVPR_009` | cruise control/vehicle speed limitation | 251=3 generation |
| `CFG_DF2_CMM_PCPR_009` | air conditioning pressure sensor | 254=without air conditioning, 247=linear pressure switch |

## Lexia measurement screens

How the official tool groups the parameters on screen. Useful if you want the same layout in your own client.

| Screen | Title | Parameters |
|---|---|---:|
| `ECRAN_FONCTIONNEL` | ECRAN_FONCTIONNEL | 1 |
| `IDENTIFICATION` | Identification | 11 |
| `INDICE_TELE` | INDIE_TELE | 1 |
| `MESUREPARAMETRE1` | mixture | 20 |
| `MESUREPARAMETRE2` | ignition | 11 |
| `MESUREPARAMETRE3` | intake circuit | 20 |
| `MESUREPARAMETRE4` | programming and adaptive values | 15 |
| `MESUREPARAMETRE5` | engine torque | 7 |
| `MESUREPARAMETRE6` | driving | 27 |
| `MESUREPARAMETRE7` | engine environment | 22 |
| `MESUREPARAMETRE8` | immobiliser | 4 |
| `MESUREPARAMETRE_TA` | Inlet camshaft dephaser | 2 |
| `VA1` | Adaptatif de richesse xSet 1 | 19 |
| `VA10` | Déphaseur admission xSet 10 | 19 |
| `VA12` | Régulation air / carburant xSet 12 | 19 |
| `VA13` | Canister xSet 13 | 17 |
| `VA14` | Gestion du couple xSet 14 | 19 |
| `VA15` | Fan assembly xSet 15 | 17 |
| `VA16` | accelerator pedal xSet 16 | 20 |
| `VA17` | Utilisation des pédales de frein/embrayage xSet 17 | 19 |
| `VA18` | empérature d'eau xSet 18 | 20 |
| `VA19` | combustion misfiring xSet 19 | 19 |
| `VA20` | cruise control xSet 20 | 20 |
| `VA21` | speed limiter xSet 21 | 20 |
| `VA22` | Catalyseur xSet 22 | 20 |
| `VA23` | Génération de courant xSet 23 | 18 |
| `VA24` | Synchronisation xSet 24 | 18 |
| `VA25` | Alimentation xSet 25 | 17 |
| `VA3` | throttle housing xSet 3 | 20 |
| `VA4` | CAN I/S xSet 4 | 15 |
| `VA5` | Climatisation xSet 5 | 17 |
| `VA6` | Cliquetis / Supercliquetis xSet 6 | 19 |
| `VA7` | CMM xSet 7 | 20 |
| `VA8` | Démarreur / DAMP xSet 8 | 16 |
| `VA9` | intake air pressure xSet 9 | 16 |
| `VA_EOBD` |  | 10 |
