## Phase 3 : Ajout de redondance de stockage pour garantir la conservation des données malgré la perte de machine

Soyons honnêtes, le contenu de cette phase a été choisi au départ de notre aventure, sans connaître le sujet. En réalité, nous avons bien senti la grande différence de difficulté en l'abordant. Jusqu'ici, les choses semblaient relativement faciles, même si nous sommes conscients que nous sommes probablement passés à côté de difficultés nombreuses qui ne manqueraient pas d'apparaître dans un vrai contexte de production. Mais, reconnaissons le, nous n'avons eu jusqu'à présent qu'à rajouter une petite couche de code qui tire parti des possibilités toutes faites fournies par la BEAM.

Nous n'allons pas raconter toutes nos tentatives et nos errements car ce serait long et fastidieux, mais plutôt tenter de présenter un chemin de découverte du problème (pas forcément de la solution, d'ailleurs) qui soit passablement linéaire.

### Redondance, vous avez dit redondance ?

Notre approche est un peu naïve : si on stocke plusieurs fois la données (redondance), on se dit intuitivement qu'on doit pouvoir la retrouver en cas de perte d'un noeud. 

Essayons déjà de la stocker plusieurs fois et on verra si on peut la retrouver après. Pour se simplifier la vie, revenons dans le cas d'un cluster statique (nombre de machines constant hors moments de pannes) et oublions donc les notions de `HashRing` de la phase 2. Pour fixer les idées, prenons 5 machines comme initialement.

Comment choisir sur quelle machine stocker la donnée et stocker les copies ? 

Au début, influencés par cette façon de poser le problème, nous sommes partis de l'idée d'un noeud "maître" et de "réplicas". Par exemple, un maître et 2 réplicas. Dans cette hypothèse, la donnée est écrite 3 fois. 

Mais est-ce que cette dissymétrie entre rôles de maître et réplicas est finalement une bonne idée ? Que se passe-t-il si le maître tombe ? Il faudrait alors se rappeler quel noeud est le nouveau, et que cette connaissance se répande correctement dans le cluster tout entier à chaque événement (perte et retour). Et finalement, à quoi bon?

Ces tâtonnements ont fait émerger une idée beaucoup plus simple, celle de **groupe**. 

Un groupe est un ensemble de noeuds définis et fixes, qui ont des rôles symétriques au sein du groupe. Voici ce que nous avons choisi. Dans le cas d'un cluster de 5 noeuds numérotés de 0 à 4, nous avons aussi 5 groupes numérotés de 0 à 4. Le groupe 0 aura les noeuds 0,1 & 2. Le groupe 4 aura les noeuds 4,0 & 1. De façon générale, le groupe `n` a les noeuds `n+1` et `n+2` modulo 5. Inversement, le noeud 0 appartiendra donc au groupe 0, 4 & 3. 

En résumé, tout groupe a 3 noeuds et tout noeud appartient à 3 groupes. Cela se traduit dans le code par:
```elixir
defp nodes_in_group(group_number) do
n = Cluster.static_nb_nodes()
[group_number, rem(group_number + 1 + n, n), rem(group_number + 2 + n, n)]
end

defp groups_of_a_node(node_number) do
n = Cluster.static_nb_nodes()
[node_number, rem(node_number - 1, n), rem(node_number - 2, n)]
end
```
Petite parenthèse, nous avons adapté le code de `Apothik.Cluster`. Voici les éléments principaux: 
```elixir
defmodule Apothik.Cluster do
  alias Apothik.Cache
  use GenServer

  @nb_nodes 5

  @hosts for i <- 0..(@nb_nodes - 1), into: %{}, do: {i, :"apothik_#{i}@127.0.0.1"}

  def static_nb_nodes(), do: @nb_nodes

  def node_name(i), do: @hosts[i]

  def number_from_node_name(node) do
    Enum.find(@hosts, fn {_, v} -> v == node end) |> elem(0)
  end

  (...etc...)
end
```

Une clé est alors assignée à un **groupe** et **non** à un noeud. La fonction `key_to_node/1` devient:
```elixir
defp key_to_group_number(k), do: :erlang.phash2(k, Cluster.static_nb_nodes())
```

## Ecritures multiples

Que va-t-il se passer quand on écrit une valeur dans le cache ? On va l'écrire 3 fois.

Tout d'abord, on peut envoyer l'ordre d'écriture à n'importe quel noeud (rappelons que l'on peut s'adresser au cache de n'importe quel noeud du cluster). Celui-ci va alors déterminer le groupe, puis retenir un noeud au hasard dans le groupe, sauf s'il se trouve que c'est lui-même auquel cas il se privilégie (petite optimisation). 

Voici ce que cela donne (attention, dans ce texte, l'ordre des fonctions est guidé par la compréhension et ne suit pas nécessairement l'ordre dans le code lui-même)

```elixir
  def put(k, v) do
    alive_node = k |> key_to_group_number() |> pick_a_live_node() |> Cluster.node_name()
    GenServer.call({__MODULE__, alive_node}, {:put, k, v})
  end

  defp pick_a_live_node(group_number) do
    case live_nodes_in_a_group(group_number) do
      [] -> nil
      l -> pick_me_if_possible(l)
    end
  end

  defp live_nodes_in_a_group(group_number),
    do: group_number |> nodes_in_group() |> Enum.filter(&alive?/1)

  defp alive?(node_number) when is_integer(node_number),
    do: node_number |> Cluster.node_name() |> alive?()

  defp alive?(node_name), do: node_name == Node.self() or node_name in Node.list()

  def pick_me_if_possible(l) do
    case Enum.find(l, fn i -> Cluster.node_name(i) == Node.self() end) do
      nil -> Enum.random(l)
      i -> i
    end
  end
```

Notez que l'on n'a pas besoin de garder l'état du cluster par ailleurs. Nous avons une topologie statique et basée sur les noms, donc `Node.list/1` est suffisant pour nous renseigner sur l'état de tel ou tel noeud.

A présent, le coeur du sujet, l'écriture multiple.
```elixir
  def handle_call({:put, k, v}, _from, state) do
    k
    |> key_to_group_number()
    |> live_nodes_in_a_group()
    |> Enum.reject(fn i -> Cluster.node_name(i) == Node.self() end)
    |> Enum.each(fn replica -> put_as_replica(replica, k, v) end)

    {:reply, :ok, Map.put(state, k, v)}
  end
```

Tout d'abord, on identifie les **autres** noeuds du groupe qui sont en fonction et on lance `put_as_replica/4` sur chacun (je sais pas si vous êtes comme nous, mais on adore les pipelines avec des belles séries de `|>` qui se lisent comme un roman). Ensuite, on modifie l'état du noeud courant avec un classique ` {:reply, :ok, Map.put(state, k, v)}`.

Quant à `put_replica/3`, c'est encore plus simple:
```elixir
  def put_as_replica(replica, k, v) do
    GenServer.cast({__MODULE__, Cluster.node_name(replica)}, {:put_as_replica, k, v})
  end
  def handle_cast({:put_as_replica, k, v}, state) do
    {:noreply, Map.put(state, k, v)}
  end
```

## Dans l'enfer du deadlock

**Attention, attention** à ce que nous avons subrepticement glissé ici. Ca n'a l'air de rien mais **c'est là que nous basculons dans l'enfer des applications distribuées**.

Touchons en un mot avant d'y revenir. Nous avons utilisé `GenServer.cast`. Et pas `GenServer.call`. Ce qui signifie que nous envoyons une bouteille à la mer pour dire à nos voisins "met à jour ton cache" mais nous n'attendons pas de retour. Rien ne nous garantit que le message a été traité. Nous n'avons pas d'acquittement. Ainsi, les noeuds du groupe n'ont **aucune garantie** d'avoir le même état. 

Pourquoi ne pas mettre un `call`, alors? 

C'est ce que nous avons fait au début, naïfs que nous étions (et nous le sommes encore; il faut visiblement des années de déniaisement dans le monde distribué). Mais nous sommes tombé dans l'enfer du **deadlock**. Si deux noeuds du groupe sont simultanément sollicités pour mettre à jour le cache, ils peuvent s'attendre indéfiniment. Dans la réalité, il y a un `timeout` standard, que l'on peut changer dans les options de `GensServer.call`. Mais il lance une exception quand il est atteint. 

Ca y est, nous sommes entrés dans la cour des grands. Plus précisément, nous l'apercevons au travers du grillage.

## Récapitulatif et tests
Voilà ce que ça donne à la fin (notez `get/1`, qui fonctionne comme attendu, et l'absence de `delete` qui serait à l'image de `put`, mais parfois la flemme sort gagnante, voilà tout)
```elixir
defmodule Apothik.Cache do
  use GenServer
  alias Apothik.Cluster

  # Play with groups
  defp nodes_in_group(group_number) do
    n = Cluster.static_nb_nodes()
    [group_number, rem(group_number + 1 + n, n), rem(group_number + 2 + n, n)]
  end

  # Check if a node is alive based on its number
  defp alive?(node_number) when is_integer(node_number),
    do: node_number |> Cluster.node_name() |> alive?()

  # Checks if a node is alive based on its name
  defp alive?(node_name), do: node_name == Node.self() or node_name in Node.list()

  defp live_nodes_in_a_group(group_number),
    do: group_number |> nodes_in_group() |> Enum.filter(&alive?/1)

  def pick_me_if_possible(l) do
    case Enum.find(l, fn i -> Cluster.node_name(i) == Node.self() end) do
      nil -> Enum.random(l)
      i -> i
    end
  end

  defp pick_a_live_node(group_number) do
    case live_nodes_in_a_group(group_number) do
      [] -> nil
      l -> pick_me_if_possible(l)
    end
  end

  defp key_to_group_number(k), do: :erlang.phash2(k, Cluster.static_nb_nodes())

  #### GenServer Interface
  def get(k) do
    alive_node = k |> key_to_group_number() |> pick_a_live_node() |> Cluster.node_name()
    GenServer.call({__MODULE__, alive_node}, {:get, k})
  end

  # Put a {key, value} in the cache
  def put(k, v) do
    alive_node = k |> key_to_group_number() |> pick_a_live_node() |> Cluster.node_name()
    GenServer.call({__MODULE__, alive_node}, {:put, k, v})
  end

  def put_as_replica(replica, k, v) do
    GenServer.cast({__MODULE__, Cluster.node_name(replica)}, {:put_as_replica, k, v})
  end

  def stats(), do: GenServer.call(__MODULE__, :stats)

  def update_nodes(_nodes), do: nil

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  #### Implementation

  @impl true
  def init(_args), do: {:ok, %{}}

  @impl true

  def handle_cast({:put_as_replica, k, v}, state), do: {:noreply, Map.put(state, k, v)}

  @impl true
  def handle_call({:get, k}, _from, state), do: {:reply, Map.get(state, k), state}

  def handle_call({:put, k, v}, _from, state) do
    k
    |> key_to_group_number()
    |> live_nodes_in_a_group()
    |> Enum.reject(fn i -> Cluster.node_name(i) == Node.self() end)
    |> Enum.each(fn replica -> put_as_replica(replica, k, v) end)

    {:reply, :ok, Map.put(state, k, v)}
  end

  def handle_call(:stats, _from, state), do: {:reply, map_size(state), state}
end
```

Vite, vérifions que ça marche. `./scripts/start_cluster.sh` dans un terminal et dans un autre:
```
 % ./scripts/start_master.sh
iex(master@127.0.0.1)1> Master.put(1, :a_key, 100)
:ok
iex(master@127.0.0.1)2> Master.stat
[{0, 0}, {1, 1}, {2, 1}, {3, 1}, {4, 0}]
iex(master@127.0.0.1)3> Master.get(3, :a_key)
100
iex(master@127.0.0.1)4> Master.put(2, :another_key, 200)
:ok
iex(master@127.0.0.1)5> Master.get(3, :another_key)
200
iex(master@127.0.0.1)6> Master.stat
[{0, 1}, {1, 1}, {2, 1}, {3, 2}, {4, 1}]
iex(master@127.0.0.1)7> Master.fill(1,5000)
:ok
iex(master@127.0.0.1)8> Master.stat
[{0, 2993}, {1, 2968}, {2, 3035}, {3, 3031}, {4, 2979}]
iex(master@127.0.0.1)9> Master.sum
15006
```

On voit bien que `:a_key` est sur 3 noeuds. On accède bien au cache de n'importe quel noeud et les données sont bien présentes et quand on a chargé les données sur le cluster, on a bien un total de `15006` valeurs stockées, qui est bien `5002 * 3`.

## Récupération de données

Que se passe-t-il en cas de perte de noeud ? Eh bien, nous perdons les données, pardi !
```
% ./scripts/start_master.sh
iex(master@127.0.0.1)1> Master.fill(1,5000)
:ok
iex(master@127.0.0.1)2> Master.kill(2)
:ok
iex(master@127.0.0.1)3> Master.stat
[  {0, 2992},  {1, 2967},  {2, {:badrpc, :nodedown}},  {3, 3029},  {4, 2978}]
```

Dans un autre terminal, `./scripts/start_instance.sh 2` (oui, nous avons écrit un petit script équivalent à `elixir --name apothik_$1@127.0.0.1 -S mix run --no-halt`) et revenons dans le `master`:
```
iex(master@127.0.0.1)4> Master.stat
[{0, 2992}, {1, 2967}, {2, 0}, {3, 3029}, {4, 2978}]
```
`apothik_2` est bien vide comme prévu.

Pour récupérer la donnée, essayons une approche toute simple: quand un noeud démarre, il interroge autour de lui pour récupérer l'information manquante. On va appeler cela "se réhydrater".
```elixir
  def init(_args) do
    me = Node.self() |> Cluster.number_from_node_name()

    for g <- groups_of_a_node(me), peer <- nodes_in_group(g), peer != me, alive?(peer) do
      GenServer.cast({__MODULE__, Cluster.node_name(peer)}, {:i_am_thirsty, g, self()})
    end

    {:ok, %{}}
  end

  def handle_cast({:i_am_thirsty, group, from}, state) do
    filtered_on_group = Map.filter(state, fn {k, _} -> key_to_group_number(k) == group end)
    GenServer.cast(from, {:drink, filtered_on_group})
    {:noreply, state}
  end

  def handle_cast({:drink, payload}, state) do
    {:noreply, Map.merge(state, payload)}
  end
```

A l'initialisation du noeud, celui-ci demande leur contenu à tous les noeuds de tous les groupes auquel il appartient (sauf à lui-même). Attention, pas exactement tout leur contenu, uniquement leur contenu au titre de l'appartenance à un groupe fixé. Par exemple, si le noeud 0, au titre du groupe 0, demande au noeud 2 son contenu, il ne veut pas récupérer le contenu du noeud 2 au titre de son appartenance au groupe 2 (qui est constitué des noeuds 2,3 & 4, donc pas du noeud 0). 

Aussi, le `{:i_am_thirsty, g, self()})` indique-t-il le groupe au titre duquel se fait la demande, ainsi que l'adresse de retour `self()`. Le noeud répondant va devoir filtrer les valeurs de sa mémoire, c'est le sens de `key_to_group_number(k) == group`. 

A la réception, c'est à dire à la réhydratation (`:drink`), on fusionne simplement les `map`. 

Est ce que ça marche? On relance le cluster, puis:
```
% ./scripts/start_master.sh
iex(master@127.0.0.1)1> Master.fill(1,5000)
:ok
iex(master@127.0.0.1)2> Master.stat
[{0, 2992}, {1, 2967}, {2, 3034}, {3, 3029}, {4, 2978}]
iex(master@127.0.0.1)3> Master.kill(2)
:ok
iex(master@127.0.0.1)4> Master.stat
[ {0, 2992},  {1, 2967},  {2, {:badrpc, :nodedown}},  {3, 3029},  {4, 2978}]
```
et dans un autre terminal `% ./scripts/start_instance.sh 2`. Retour dans le `master`
```
iex(master@127.0.0.1)5> Master.stat
[{0, 2992}, {1, 2967}, {2, 3034}, {3, 3029}, {4, 2978}]
```

## Ca marche ...mais que c'est moche, mon dieu, que c'est moche

Il y a tellement de choses criticables qu'on ne sait pas par où commencer. 

Lançons nous: 
- ça n'est pas très économe : le noeud peut recevoir plusieurs réponses. Pour y rémédier, il pourrait par exemple ignorer les retours dès qu'il a rafraichi les données d'un groupe. Mais même dans ce cas, le mal est fait et chaque noeud du groupe a déjà concocté une réponse, ou bien est en train de le faire. Donc il faut être probablement plus subtil
- on envoie en un seul message un tiers de la mémoire du noeud. Dans le cas d'un vrai cache, cette opération n'est sans doute pas possible (quelle est la taille maximale d'un message dans la BEAM ? nous l'ignorons, mais elle doit être limitée). De plus, il nous semble bien que l'envoi d'un message implique une recopie de son contenu avant envoi (pas sûr pour les processus inter-noeud, mais ce serait handicapant). En outre, l'opération risque de bloquer tous les noeuds qui répondent pendant un temps sensible, ce qui n'est pas acceptable dans le cas d'un cluster en forte activité
- et surtout, que se passe-t-il si en parallèle le cache est modifié? Les modifications (`put`) peuvent intervenir dans n'importe quelle ordre de séquence. Rien ne garantit que les retours des noeuds d'un même groupe (ceux captés dans `:drink`) offrent la même vision du monde. On peut tout à fait imaginer des scénarios où ils écrasent des données toutes neuves avec leurs anciennes valeurs.

Et c'est sans compter les soucis réseau, avec des latences et des déconnections qui peuvent isoler des noeuds pendant quelques millisecondes et désynchroniser l'état du cluster sur un ou plusieurs groupes.

## Est-ce que ça marche vraiment?

C'est à ce moment-là que nous sommes partis sur une pente que les informaticiens connaissent bien, et qui a été parfaitement imagée par [l'écureuil du film "l'age de glâce"](https://en.wikipedia.org/wiki/Scrat). Nous avons essayé de colmater la première brêche, puis la deuxième, mais la première en a ouvert une troisième, etc.

Car, oui, nous avions toujours notre ambition initiale en tête. Vous vous souvenez "Ajout de redondance de stockage pour garantir la conservation des données malgré la perte de machine".
Peut-être que le **"garantir"** était fortement présomptueux, après tout. 

Et là nous est revenue la phrase de [Johanna Larsonn](https://www.youtube.com/watch?v=7yU9mvwZKoY), qui disait à peu près "Attention, les applications distribuées c'est extrêment difficile mais il y a quand même des cas où l'on peut se lancer". 

Le mot "garantir" nous a entrainé trop loin. 

Après toutes ces erreurs, nous avons compris que ce qui fait la difficulté d'un système distribué, ce sont les **qualités** que l'on en attend. Et là nous avons voulu inconsciemment offrir à notre cache distribué une partie des qualités d'une base de données distribuée, ce qui est clairement au-delà de nos faibles forces de débutants.

En résumé, **non**, cela ne marche pas. En tout cas si l'on ambitionne d'aller au bout de notre phase 3 avec son titre ronflant et présomptueux.

## Peut-on viser plus bas ?

Mais peut-être que nous pourrions nous concentrer sur les qualités attendues d'un **cache**, et pas plus.

Et c'est le principal morceau de sagesse que nous a procuré notre travail jusqu'ici. **Il faut avant tout préciser clairement les qualités attendues de l'application distribuée.**. Chaque qualité se payant très cher.

A ce sujet, il nous revient  que nous avons lu un jour un fameux théorême qui explique qu'il est mathématiquement impossible **de tout avoir à la fois**: le [théorême CAP](https://en.wikipedia.org/wiki/CAP_theorem). Et ce ne doit pas le seul théorême d'impossibilité.

En application distribuée, "le beurre et l'argent du beurre" est encore plus inatteignable que d'habitude.

Revenons à notre entreprise de coupe claire dans nos ambitions. Ce que nous voulons pour notre **cache**, c'est 
- minimiser les "loupés" ("cache miss" en franglais), c'est à dire le nombre de fois où le cache ne peut fournir la valeur
- garantir dans la plupart des cas "normaux" que la valeur retournée est bien la dernière fournie au cluster. A ce stade, nous disons "cas normaux" car notre échec tout frais nous a appris à être modeste et qu'on se doute bien que "tous les cas" sera bien trop difficile pour nous.
