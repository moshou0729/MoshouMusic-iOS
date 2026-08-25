// 酷我音乐源脚本 (真实可用版)
// 端点均已验证:
//   搜索:   http://search.kuwo.cn/r.s (client=mobi, 无需鉴权)
//   播放:   http://antiserver.kuwo.cn/anti.s?type=convert_url3 (128k/320k/flac 按音质请求)
//   歌词:   http://m.kuwo.cn/newh5/singles/songinfoandlrc (lrclist + songinfo.pic)
;(function() {
    const source = 'kw'

    lx.send(EVENT_NAMES.inited, {
        sources: ['kw'],
        qualities: ['128k', '320k', 'flac']
    })

    lx.on(EVENT_NAMES.request, function(data, callback) {
        const { source: src, action, info } = data

        if (src !== source) return

        switch (action) {
            case 'musicSearch': handleSearch(info, callback); break
            case 'musicUrl':   handleMusicUrl(info, callback); break
            case 'lyric':      handleLyric(info, callback); break
            case 'pic':        handlePic(info, callback); break
            case 'musicBoard': handleBoard(info, callback); break
            default: callback({ message: '未知操作: ' + action }, null)
        }
    })

    const HEADERS = {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 14_7_1 like Mac OS X) AppleWebKit/605.1.15',
        'Referer': 'http://m.kuwo.cn/'
    }

    // 酷我 r.s 接口返回的是单引号伪 JSON，用 eval 解析 (其为合法 JS 对象字面量)
    function parseBody(body) {
        if (!body) return null
        try { return JSON.parse(body) } catch (e) {}
        try { return eval('(' + body + ')') } catch (e) {}
        return null
    }

    function cleanText(s) {
        return (s || '').replace(/&nbsp;/g, ' ').trim()
    }

    function ridOf(songmid) {
        return String(songmid).replace('MUSIC_', '')
    }

    // ==================== 搜索 ====================
    function handleSearch(info, callback) {
        const keyword = info.keyword || ''
        const page = info.page || 1
        const rn = 30

        const url = 'http://search.kuwo.cn/r.s?all=' + encodeURIComponent(keyword) +
            '&ft=music&client=mobi&cluster=0&itemset=web_www' +
            '&pn=' + (page - 1) + '&rn=' + rn +
            '&rformat=json&encoding=utf8'

        lx.request(url, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { callback(err, null); return }

            const result = parseBody(resp.body)
            if (!result || !result.abslist) {
                callback({ message: '搜索接口返回异常 (HTTP ' + resp.statusCode + ')' }, null)
                return
            }

            const list = result.abslist.map(function(item) {
                const rid = ridOf(item.MUSICRID || '')
                const name = cleanText(item.SONGNAME || item.NAME)
                return {
                    songmid: rid,
                    name: name || '未知歌曲',
                    singer: cleanText(item.ARTIST) || '未知歌手',
                    albumName: cleanText(item.ALBUM),
                    albumId: String(item.ALBUMID || ''),
                    img: '',
                    interval: parseInt(item.DURATION || '0', 10) || 0,
                    quality: '320k'
                }
            }).filter(function(item) { return item.songmid && item.name })

            callback(null, { list: list, total: parseInt(result.TOTAL || '0', 10) || list.length })
        })
    }

    // ==================== 播放链接 ====================
    function qualityToBr(quality) {
        switch (quality) {
            case 'flac': return '2000k'
            case '320k': return '999k'
            default:     return '128k'
        }
    }

    function requestUrl(rid, br, callback) {
        const url = 'http://antiserver.kuwo.cn/anti.s?type=convert_url3' +
            '&rid=' + rid + '&format=mp3' +
            (br ? '&br=' + br : '') + '&response=json'

        lx.request(url, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { callback(err, null); return }
            try {
                const result = JSON.parse(resp.body)
                if (result.code === 200 && result.url) {
                    callback(null, result.url)
                } else {
                    callback({ message: '获取播放链接失败: ' + (result.msg || ('HTTP ' + resp.statusCode)) }, null)
                }
            } catch (e) {
                callback({ message: '播放接口返回非 JSON: HTTP ' + resp.statusCode }, null)
            }
        })
    }

    function handleMusicUrl(info, callback) {
        const rid = ridOf(info.songmid)
        const quality = info.quality || '320k'

        requestUrl(rid, qualityToBr(quality), function(err, url) {
            if (err && quality !== '128k') {
                // 高音质失败时降级到 128k 重试
                requestUrl(rid, '128k', function(err2, url2) {
                    if (err2) { callback(err2, null); return }
                    callback(null, { url: url2 })
                })
                return
            }
            if (err) { callback(err, null); return }
            callback(null, { url: url })
        })
    }

    // ==================== 排行榜 ====================
    // 用酷我官方榜单接口 kbangserver（已验证返回 musiclist）
    // id: 93=飙升榜 / 16=热歌榜 / 158=新歌榜
    // 注意: 之前这里是「并发 3 个搜索再合并」，一旦某个请求不回调，
    //       计数器永远凑不齐，榜单就一直空白；且并发回调操作共享变量不安全。
    //       现已改成单请求 + 串行兜底。
    const BOARD_IDS = { '93': '飙升榜', '16': '热歌榜', '158': '新歌榜' }

    function handleBoard(info, callback) {
        const bangId = (info && info.bangId) ? String(info.bangId) : '93'
        const id = BOARD_IDS[bangId] ? bangId : '93'

        const url = 'http://kbangserver.kuwo.cn/ksong.s?from=pc&fmt=json' +
            '&pn=0&rn=50&type=bang&data=content&id=' + id +
            '&show_copyright_off=0&pcmp4=1'

        lx.request(url, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { fallbackBoard(callback); return }

            const result = parseBody(resp.body)
            if (!result || !result.musiclist || !result.musiclist.length) {
                fallbackBoard(callback)
                return
            }

            const list = result.musiclist.map(function(item) {
                return {
                    songmid: String(item.id || item.rid || ''),
                    name: cleanText(item.name) || '未知歌曲',
                    singer: cleanText(item.artist) || '未知歌手',
                    albumName: cleanText(item.album),
                    albumId: String(item.albumid || ''),
                    img: item.pic || '',
                    interval: parseInt(item.duration || '0', 10) || 0,
                    quality: '320k'
                }
            }).filter(function(item) { return item.songmid && item.name })

            if (!list.length) { fallbackBoard(callback); return }
            callback(null, { list: list, total: list.length })
        })
    }

    // 榜单接口失效时，退回单次热门关键词搜索（串行，不做并发合并）
    const HOT = ['热门歌曲', '孤勇者', '晴天', '起风了']

    function fallbackBoard(callback) {
        let idx = 0
        function tryNext() {
            if (idx >= HOT.length) {
                callback({ message: '榜单与兜底搜索均无结果' }, null)
                return
            }
            const kw = HOT[idx++]
            handleSearch({ keyword: kw, page: 1 }, function(err, data) {
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
        const rid = ridOf(info.songmid)
        fetchSongInfo(rid, function(err, data) {
            if (err) { callback(err, null); return }
            let lrc = ''
            if (data.lrclist && data.lrclist.length) {
                lrc = data.lrclist.map(function(item) {
                    const t = parseFloat(item.time) || 0
                    const min = Math.floor(t / 60)
                    const sec = Math.floor(t % 60)
                    const ms = Math.floor((t - Math.floor(t)) * 100)
                    return '[' + min + ':' + String(sec).padStart(2, '0') + '.' + String(ms).padStart(2, '0') + ']' + (item.lineLyric || '')
                }).join('\n')
            }
            callback(null, { lyric: lrc, tlyric: '' })
        })
    }

    // ==================== 封面 ====================
    function handlePic(info, callback) {
        const rid = ridOf(info.songmid)
        fetchSongInfo(rid, function(err, data) {
            if (err) { callback(err, null); return }
            const pic = (data.songinfo && (data.songinfo.pic || data.songinfo.albumpic)) || ''
            callback(null, { url: pic })
        })
    }

    // ==================== 歌曲详情 (歌词+封面共用) ====================
    function fetchSongInfo(rid, callback) {
        lx.request('http://m.kuwo.cn/newh5/singles/songinfoandlrc?musicId=' + rid, {
            method: 'GET',
            headers: HEADERS,
            timeout: 15
        }, function(err, resp) {
            if (err) { callback(err, null); return }
            try {
                const result = JSON.parse(resp.body)
                if (result.data) {
                    callback(null, result.data)
                } else {
                    callback({ message: '歌曲详情查询失败: ' + (result.msg || '无数据') }, null)
                }
            } catch (e) {
                callback({ message: '详情接口返回非 JSON' }, null)
            }
        })
    }
})()
