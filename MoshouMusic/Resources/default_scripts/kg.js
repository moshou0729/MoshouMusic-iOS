// 酷狗音乐源脚本 (真实可用版 · 2026-08 重写)
//
// 为什么重写：
//   旧版用 www.kugou.com/yy/index.php?r=play/getdata 取播放链接，现返回 err_code:30020（已废弃），
//   表现就是「点播放没反应」。
//
// 现在的方案（端点均已实测）：
//   搜索:  https://songsearch.kugou.com/song_search_v2?keyword=&page=&pagesize=
//   播放:  https://trackercdn.kugou.com/i/v2/?key=<md5(hash小写 + "kgcloudv2")>&hash=&br=&appid=1005&pid=2&cmd=25&behavior=play
//          ★ behavior=play 是关键参数，缺了会被拒；返回 JSON 的 url 是数组，取第一个可用项
//   榜单:  http://mobiles.kugou.com/api/v3/rank/song?rankid=8888&page=1&pagesize=
//   歌词:  http://krcs.kugou.com/search (搜 candidates) → http://lyrics.kugou.com/download (取内容)
//
// 播放链接依赖 hash，所以搜索结果必须把 hash 放进 meta 带下来。
// iOS 14 的 JavaScriptCore 不支持 async/await 与 Promise，全部写成回调式。
;(function() {
    const source = 'kg'

    lx.send(EVENT_NAMES.inited, {
        sources: ['kg'],
        qualities: ['128k', '320k', 'flac']
    })

    lx.on(EVENT_NAMES.request, function(data, callback) {
        const { source: src, action, info } = data
        if (src !== source) return

        switch (action) {
            case 'musicSearch': handleSearch(info, callback); break
            case 'musicUrl':    handleMusicUrl(info, callback); break
            case 'lyric':       handleLyric(info, callback); break
            case 'pic':         handlePic(info, callback); break
            case 'musicBoard':  handleBoard(info, callback); break
            default: callback({ message: '未知操作: ' + action }, null)
        }
    })

    const HEADERS = {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 14_7_1 like Mac OS X) AppleWebKit/605.1.15',
        'Referer': 'https://www.kugou.com/'
    }
    const MOBILE_HEADERS = {
        'User-Agent': 'Android712-AndroidPhone-8983-18-0-NetMusic-wifi'
    }

    function parseJSON(body) {
        if (!body) return null
        try { return JSON.parse(body) } catch (e) { return null }
    }

    function cleanText(s) {
        // 酷狗搜索结果里歌名/歌手常带 <em> 高亮标签
        return String(s || '')
            .replace(/<[^>]+>/g, '')
            .replace(/&nbsp;/g, ' ')
            .trim()
    }

    // 音质 → 优先使用的 hash 字段 + br 参数
    function pickHash(item, quality) {
        const sq = item.SQFileHash || item.sqhash || ''
        const hq = item.HQFileHash || item.hqhash || ''
        const std = item.FileHash || item.hash || ''

        if (quality === 'flac' && sq) return { hash: sq, br: 'sq' }
        if (quality === '320k' && hq) return { hash: hq, br: 'hq' }
        return { hash: std, br: '' }
    }

    // ==================== 搜索 ====================
    function handleSearch(info, callback) {
        const keyword = info.keyword || ''
        const page = info.page || 1

        const url = 'https://songsearch.kugou.com/song_search_v2?keyword=' +
            encodeURIComponent(keyword) + '&page=' + page + '&pagesize=30' +
            '&userid=0&clientver=&platform=WebFilter&tag=em&filter=2&iscorrection=1&privilege_filter=0'

        lx.request(url, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { callback(err, null); return }

            const result = parseJSON(resp.body)
            const arr = result && result.data && result.data.lists
            if (!arr || !arr.length) {
                callback({ message: '酷狗搜索无结果 (HTTP ' + resp.statusCode + ')' }, null)
                return
            }

            const list = []
            for (let i = 0; i < arr.length; i++) {
                const item = arr[i]
                const hash = item.FileHash || item.HQFileHash || item.SQFileHash
                if (!hash) continue

                list.push({
                    songmid: String(hash),
                    name: cleanText(item.SongName || item.FileName) || '未知歌曲',
                    singer: cleanText(item.SingerName) || '未知歌手',
                    albumName: cleanText(item.AlbumName),
                    albumId: String(item.AlbumID || ''),
                    img: '',
                    interval: parseInt(item.Duration || '0', 10) || 0,
                    quality: item.SQFileHash ? 'flac' : (item.HQFileHash ? '320k' : '128k'),
                    // 播放需要多档 hash，全部带下去
                    meta: {
                        hash: String(hash),
                        hqHash: String(item.HQFileHash || ''),
                        sqHash: String(item.SQFileHash || ''),
                        albumId: String(item.AlbumID || ''),
                        albumAudioId: String(item.MixSongID || item.Audioid || '')
                    }
                })
            }

            if (!list.length) {
                callback({ message: '酷狗搜索结果均无可用 hash' }, null)
                return
            }
            callback(null, { list: list, total: (result.data.total || list.length) })
        })
    }

    // ==================== 播放链接 ====================
    function requestUrl(hash, br, callback) {
        const h = String(hash).toLowerCase()
        // key = md5(hash小写 + "kgcloudv2")，由宿主提供的 lx.utils.crypto.md5 计算
        const key = lx.utils.crypto.md5(h + 'kgcloudv2')

        let url = 'https://trackercdn.kugou.com/i/v2/?key=' + key +
            '&hash=' + h + '&appid=1005&pid=2&cmd=25&behavior=play'
        if (br) url += '&br=' + br

        lx.request(url, { method: 'GET', headers: MOBILE_HEADERS, timeout: 20 }, function(err, resp) {
            if (err) { callback(err, null); return }

            const result = parseJSON(resp.body)
            if (!result) {
                callback({ message: '酷狗播放接口返回非 JSON (HTTP ' + resp.statusCode + ')' }, null)
                return
            }
            if (result.status !== 1) {
                callback({ message: '酷狗播放被拒: status=' + result.status + ' ' + (result.error || '') }, null)
                return
            }

            // url 是数组，逐个挑第一个 http 开头的
            let picked = ''
            const urls = result.url
            if (urls instanceof Array) {
                for (let i = 0; i < urls.length; i++) {
                    if (urls[i] && String(urls[i]).indexOf('http') === 0) { picked = String(urls[i]); break }
                }
            } else if (typeof urls === 'string' && urls.indexOf('http') === 0) {
                picked = urls
            }

            if (!picked) {
                callback({ message: '酷狗未返回可用链接（可能需要会员）' }, null)
                return
            }
            callback(null, picked)
        })
    }

    function handleMusicUrl(info, callback) {
        const quality = info.quality || '320k'

        // 按目标音质挑 hash，逐级降级：flac → 320k → 128k
        const chain = []
        if (quality === 'flac' && info.sqHash) chain.push({ hash: info.sqHash, br: 'sq' })
        if ((quality === 'flac' || quality === '320k') && info.hqHash) chain.push({ hash: info.hqHash, br: 'hq' })
        const base = info.hash || info.songmid
        if (base) chain.push({ hash: base, br: '' })

        if (!chain.length) { callback({ message: '缺少歌曲 hash' }, null); return }

        let idx = 0
        function tryNext() {
            if (idx >= chain.length) {
                callback({ message: '酷狗所有音质均无法播放' }, null)
                return
            }
            const cur = chain[idx++]
            requestUrl(cur.hash, cur.br, function(err, url) {
                if (!err && url) { callback(null, { url: url }); return }
                tryNext()
            })
        }
        tryNext()
    }

    // ==================== 排行榜 ====================
    // rankid: 8888=酷狗飙升榜 / 6666=酷狗TOP500 / 31308=网络红歌榜
    function handleBoard(info, callback) {
        const rankId = (info && info.bangId) ? String(info.bangId) : '8888'

        const url = 'http://mobiles.kugou.com/api/v3/rank/song?version=9108' +
            '&ranktype=1&plat=0&pagesize=50&area_code=1&page=1' +
            '&rankid=' + rankId + '&with_res_tag=0'

        lx.request(url, { method: 'GET', headers: MOBILE_HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { fallbackBoard(callback); return }

            const result = parseJSON(resp.body)
            const arr = result && result.data && result.data.info
            if (!arr || !arr.length) { fallbackBoard(callback); return }

            const list = []
            for (let i = 0; i < arr.length; i++) {
                const item = arr[i]
                const hash = item.hash || item.hqhash || item.sqhash
                if (!hash) continue

                let singer = ''
                if (item.authors && item.authors.length) {
                    const names = []
                    for (let j = 0; j < item.authors.length; j++) {
                        if (item.authors[j] && item.authors[j].author_name) {
                            names.push(item.authors[j].author_name)
                        }
                    }
                    singer = names.join('/')
                }
                if (!singer) singer = cleanText(item.singername)

                list.push({
                    songmid: String(hash),
                    name: cleanText(item.songname || item.filename) || '未知歌曲',
                    singer: singer || '未知歌手',
                    albumName: cleanText(item.album_name),
                    albumId: String(item.album_id || ''),
                    img: item.album_sizable_cover
                        ? String(item.album_sizable_cover).replace('{size}', '240')
                        : '',
                    interval: parseInt(item.duration || '0', 10) || 0,
                    quality: item.sqhash ? 'flac' : (item.hqhash ? '320k' : '128k'),
                    meta: {
                        hash: String(hash),
                        hqHash: String(item.hqhash || ''),
                        sqHash: String(item.sqhash || ''),
                        albumId: String(item.album_id || ''),
                        albumAudioId: String(item.album_audio_id || '')
                    }
                })
            }

            if (!list.length) { fallbackBoard(callback); return }
            callback(null, { list: list, total: list.length })
        })
    }

    const HOT = ['热门歌曲', '抖音热歌', '孤勇者']

    function fallbackBoard(callback) {
        let idx = 0
        function tryNext() {
            if (idx >= HOT.length) {
                callback({ message: '酷狗榜单与兜底搜索均无结果' }, null)
                return
            }
            handleSearch({ keyword: HOT[idx++], page: 1 }, function(err, data) {
                if (!err && data && data.list && data.list.length) {
                    callback(null, { list: data.list.slice(0, 30), total: data.list.length })
                } else {
                    tryNext()
                }
            })
        }
        tryNext()
    }

    // ==================== 歌词 ====================
    function handleLyric(info, callback) {
        const hash = info.hash || info.songmid
        if (!hash) { callback({ message: '缺少歌曲 hash' }, null); return }

        // 第一步：按 hash 搜候选歌词，拿到 id + accesskey
        const searchUrl = 'http://krcs.kugou.com/search?ver=1&man=yes&client=mobi&hash=' +
            encodeURIComponent(String(hash))

        lx.request(searchUrl, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { callback(err, null); return }

            const result = parseJSON(resp.body)
            const cands = result && result.candidates
            if (!cands || !cands.length) {
                callback(null, { lyric: '', tlyric: '' })
                return
            }

            const c = cands[0]
            // 第二步：下载歌词内容（decode=1 直接返回明文 LRC）
            const dlUrl = 'http://lyrics.kugou.com/download?ver=1&client=pc&fmt=lrc&charset=utf8' +
                '&accesskey=' + encodeURIComponent(c.accesskey) +
                '&id=' + encodeURIComponent(c.id) + '&decode=1'

            lx.request(dlUrl, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err2, resp2) {
                if (err2) { callback(null, { lyric: '', tlyric: '' }); return }
                const r2 = parseJSON(resp2.body)
                callback(null, { lyric: (r2 && r2.content) || '', tlyric: '' })
            })
        })
    }

    // ==================== 封面 ====================
    function handlePic(info, callback) {
        const hash = info.hash || info.songmid
        if (!hash) { callback(null, { url: '' }); return }

        const url = 'http://mobilecdn.kugou.com/api/v3/song/info?hash=' +
            encodeURIComponent(String(hash)) + '&version=9108&plat=0'

        lx.request(url, { method: 'GET', headers: MOBILE_HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { callback(null, { url: '' }); return }
            const result = parseJSON(resp.body)
            let pic = (result && result.data && (result.data.imgUrl || result.data.album_sizable_cover)) || ''
            if (pic) pic = String(pic).replace('{size}', '480')
            callback(null, { url: pic })
        })
    }
})()
