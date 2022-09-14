require "ed25519"
require 'digest'
require 'sha3'
require "base32"
require 'json'
require "net/http"
require 'rubygems'
require 'active_record'

def load_catjson(tx,network) 

	if tx["type"] === "AGGREGATE_COMPLETE" || tx["type"] === "AGGREGATE_BONDED" then
		json_file =  "aggregate.json"
	else
		json_file =  tx["type"].downcase + ".json"
	end

	uri = URI.parse(network["catjasonBase"] + json_file)
	json = Net::HTTP.get(uri)
	result = JSON.parse(json)
	
	return result

end

def load_layout(tx,catjson,is_embedded) 

	if is_embedded then
		prefix = "Embedded"
	else
		prefix = ""
	end

	if    tx["type"] === "AGGREGATE_COMPLETE" then 
		layout_name = "AggregateCompleteTransaction"
	elsif tx["type"] === "AGGREGATE_BONDED" then 
		layout_name = "AggregateBondedTransaction"
	else
		puts "aaaa".camelize

		layout_name = prefix + tx["type"].downcase.camelize + "Transaction"
		puts layout_name
	end


	factory = catjson.find{|item| item['factory_type'] == prefix + "Transaction" && item["name"]  == layout_name}
	puts factory["layout"]



	return factory["layout"]
end



def prepare_transaction(tx,layout,network) 

	prepared_tx = Marshal.load(Marshal.dump(tx))
	prepared_tx["network"] = network["network"]
	prepared_tx["version"] = network["version"]

	if prepared_tx.has_key?("message") then

		prepared_tx['message'] = "00" +  tx['message'].unpack('H*')[0]
	end 

	if prepared_tx.has_key?("name") then

		prepared_tx['name'] = tx['name'].unpack('H*')[0]
	end 

	if prepared_tx.has_key?("value") then

		prepared_tx['value'] = tx['value'].unpack('H*')[0]
	end 


	if prepared_tx.has_key?("mosaics") then
		prepared_tx['mosaics'] = (
			tx['mosaics'].sort do |a, b|
				b["mosaic_id"] <=> a["mosaic_id"]
			end
		)
	end

	layout.each{|layer|

		if layer.has_key?("size") && layer["size"].kind_of?(String)  then

			size = 0
			if layer.has_key?("element_disposition") && prepared_tx.has_key?(layer["name"]) then
				size = prepared_tx[layer["name"]].length / (layer["element_disposition"]["size"] * 2)
			elsif layer["size"].include?("_count") != false then
				if prepared_tx.has_key?(layer["name"]) then
					size = prepared_tx[ layer["name"] ].length
				else
					size = 0
				end
			else
				#その他のsize値はPayloadの長さを入れるため現時点では不明
			end
			prepared_tx[ layer["size"] ] = size
		else
			puts "else"

		end
	}

	if tx.has_key?("transactions") then
		txes = []
		tx["transactions"].each{|e_tx|

			e_catjson = load_catjson(e_tx,network)
			e_layout = load_layout(e_tx,e_catjson,true)
			e_prepared_tx = prepare_transaction(e_tx,e_layout,network)
			txes.push(e_prepared_tx)
		}
	end
	puts prepared_tx
	return prepared_tx




end

def parse_transaction(tx,layout,catjson,network) 
	parsed_tx = [] #return
	layout.each{|layer|


		layer_type = layer["type"]
		layer_disposition = ""
		if layer.has_key?("disposition") then
			layer_disposition = layer["disposition"]
		end

		catitem = Marshal.load(Marshal.dump(catjson.find{|cf| cf["name"] == layer_type}))

		puts "■■■■■■■■■■"
		puts layer_type
		puts catitem

		if layer.has_key?("condition") then
			if layer["condition_operation"] == "equals" then
				if layer["condition_value"] != tx[layer["condition"]] then
					next
				end
			end
		end


		if layer_disposition == "const" then
			next

		elsif layer_type === "EmbeddedTransaction" then

			tx_layer = Marshal.load(Marshal.dump(layer))

			items = []
			tx["transactions"].each{ |e_tx|#小文字のeはembeddedの略
				e_catjson = load_catjson(e_tx,network) #catjsonの更新
				e_layout = load_layout(e_tx,e_catjson,true) #isEmbedded:true

				e_parsed_tx = parse_transaction(e_tx,e_layout,e_catjson,network) #再帰
				items.push(e_parsed_tx)
			}
			
			tx_layer["layout"] = items
			parsed_tx.push(tx_layer)
			next

		elsif !catitem.nil? &&catitem.has_key?("layout") && tx.has_key?(layer["name"]) then

			tx_layer = Marshal.load(Marshal.dump(layer))
			items = []
			tx[layer["name"]].each{|item|

				filter_layer = catjson.find{|cj| cj['name'] == layer_type}
				item_parsed_tx = parse_transaction(item,filter_layer["layout"],catjson,network) #再帰
				items.push(item_parsed_tx)
			}

			tx_layer["layout"] = items
			parsed_tx.push(tx_layer)
			next

		elsif layer_type == "UnresolvedAddress" then


			puts layer["name"]
			#アドレスに30個の0が続く場合はネームスペースとみなします。
			if tx.has_key?(layer["name"]) && !tx[layer["name"]].kind_of?(Array) && tx[layer["name"]].include?('000000000000000000000000000000') == true then

#				let prefix = (catjson.find{|cf| cf["name"] =="NetworkType"}).["values"].find{|vf| vf["name"] == tx["network"]}.["value"] + 1).pack("C").unpack('H*')[0]
				network_type = catjson.find{|cf| cf["name"] =="NetworkType"}
				network_value = network_type["values"].find{|vf| vf["name"] == tx["network"]}
				prefix =  [network_value + 1].pack("C").unpack('H*')[0]
				tx[layer["name"]] =  prefix +  tx[layer["name"]]
			end

		elsif !catitem.nil? && catitem.has_key?("type") && catitem["type"] == "enum" then

			if catitem["name"].include?('Flags') == true then

				value = 0
				catitem["values"].each{|item_layer| 

					if tx[layer["name"]].include?(item_layer["name"]) == true then

						value += item_layer["value"]
					end
				}
				catitem["value"] = value
			
			elsif layer_disposition.include?('array') == true then

				values = []
				tx[layer["name"]].each{|item| 

					item_value = catitem["values"].find{|cj| cj["name"] == item}["value"]
					values.push(item_value)
				}
				tx[layer["name"]] = values
			else
				puts catitem["values"]
				catitem["value"] = catitem["values"].find{|cj| cj["name"] == tx[layer["name"]]}["value"]
			end
		end


		#//layerの配置
		if layer_disposition.include?('array') == true then

			size = 0
			if tx.has_key?(layer["size"]) == true then
				size = tx[layer["size"]]
			end

			if layer_type == "byte" then

				if layer.has_key?("element_disposition") then

					sub_layout = Marshal.load(Marshal.dump(layer))

					items = []
					for count in Range.new(0, size) do
						tx_layer = {}
						tx_layer["signedness"] = layer["element_disposition"]["signedness"]
						tx_layer["name"] = "element_disposition"
						tx_layer["size"] = layer["element_disposition"]["size"]
						tx_layer["value"] = tx[layer["name"]].slice(count * 2, 2)
						tx_layer["type"] = layer_type
						items.push(tx_layer)
						
					end

					sub_layout["layout"] = items
					parsed_tx.push(sub_layout)

				else
					puts "not yet"
				end
			elsif tx.has_key?(layer["name"]) then


				sub_layout = Marshal.load(Marshal.dump(layer))
				items = []
				tx[layer["name"]].each{|tx_item| 

					tx_layer = catjson.find{|cj| cj["name"] == layer_type }
					tx_layer["value"] = tx_item
					
					if layer_type == "UnresolvedAddress" then
						#アドレスに30個の0が続く場合はネームスペースとみなします。
						if tx_item.include('000000000000000000000000000000') == true then

							network_type = catjson.find{|cj| cj["name"] === "NetworkType"}
							network_value = network_type["values"].find{|cj| cj["name"] == tx["network"]}["value"]
							prefix =  [network_value + 1].pack("C").unpack('H*')[0]
							tx_layer["value"] =  prefix . tx_layer["value"]
						end
					end			
					items.push(tx_layer)
				}
				sub_layout["layout"] = items
				parsed_tx.push(sub_layout)

			else
				puts "not yet"
			end
		else #reserved またはそれ以外(定義なし)

			tx_layer = Marshal.load(Marshal.dump(layer))

			if !catitem.nil? && catitem.size  > 0 then

				tx_layer["signedness"]	= catitem["signedness"]
				tx_layer["size"]  = catitem["size"]
				tx_layer["type"]  = catitem["type"]
				tx_layer["value"] = catitem["value"]
			end

			#txに指定されている場合上書き(enumパラメータは上書きしない)
			if layer.has_key?("name") && tx.has_key?(layer["name"]) then
				if !catitem.nil? && catitem.has_key?("type") && catitem["type"] == "enum" then

				else
					tx_layer["value"] = tx[layer["name"]]
				end
			else

			end
			parsed_tx.push(tx_layer)
		end

	}

	puts parsed_tx
	layer_size = parsed_tx.find{|pf| pf["name"] == "size"}

	if !layer_size.nil? && layer_size.has_key?("size") then

		layer_size["value"] = count_size(parsed_tx)
	end
	return parsed_tx
#	return 0	
	
end

def count_size(item,alignment = 0) 


	total_size = 0;
	
	#//レイアウトサイズの取得
	if !item.nil?  && item.kind_of?(Hash) && item.has_key?("layout") then
		item["layout"].each{|layer|

			if item.has_key?("alignment") then
				item_alignment = item["alignment"]
			else
				item_alignment = 0
			end
			total_size += count_size(layer,item_alignment) # 再帰
		}
	#//レイアウトを構成するレイヤーサイズの取得
	elsif  item.kind_of?(Array) then

		layout_size = 0
		item.each{|layout|

			layout_size += count_size(layout,alignment)#再帰
		}

		if alignment > 0 then
			fvalue = (layout_size  + alignment - 1) / alignment
			layout_size = fvalue.floor * alignment
		end
		total_size += layout_size
	
	else

		if item.kind_of?(Hash) && item.has_key?("size") then

			total_size += item["size"];
		else
			puts "no size:" + item["name"]
		end
	end

	return total_size


#	return 0
end

def build_transaction(parsed_tx) 
	return 0
end

def hexlify_transaction(item,alignment = 0) 
	return 0
end

def sign_transaction(built_tx,private_key,network) 
	return 0
end

def get_verifiable_data(built_tx) 
	return 0
end

def hash_transaction(signer,signature,built_tx,network) 
	return 0
end

def update_transaction(built_tx,name,type,value) 
	return 0
end

def cosign_transaction(tx_hash,private_key) 
end

def generate_address_id(address) 
	return 0
end

def generate_namespace_id(name, parent_namespace_id = 0)
	return 0
end	

def generate_key(name)
	return 0
end

def generate_mosaic_id(owner_address, nonce)
	return 0
end

def convert_address_alias_id(namespace_id)
	return 0
end

def digest_to_bigint(digest)
	return 0
end
